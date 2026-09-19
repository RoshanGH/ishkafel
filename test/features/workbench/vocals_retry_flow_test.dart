import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/analysis/silence_detector.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/audio/vocal_separator.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/settings/settings_providers.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';
import 'package:ishkafel/features/workbench/workbench_page.dart';

/// 界面上的「重新分离」是这次修复真正交付给用户的东西。
///
/// 真机事故（2026-09-04）：两条任务共用一条源片，先分析那条被删时把人声轨
/// 一起带走了，另一条从此一直挂着「没有分离出纯人声轨」——而且提示叫他
/// 「重新分析」，那条路命中缓存直接返回，走不到分离那一步，做多少遍都白搭。
///
/// 所以这条提示必须给一个**真能解决问题**的出口：就地补分离这一份，
/// 十几秒的事，不重跑几分钟的分析。
class _Repo implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async => _store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}

class _FakeAsr implements AsrProvider {
  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async => const [];
}

class _FakeSplitter implements SemanticSplitter {
  @override
  Future<List<UnitDraft>> split(List<AsrSentence> sentences) async => const [];
}

TimelineMediaBuilder _fakeMediaBuilder() => TimelineMediaBuilder(
      thumbnails: ThumbnailService(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(600, 1));
        return ProcessResult(1, 0, '', '');
      }),
      audio: AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(64, 0));
        return ProcessResult(1, 0, '', '');
      }),
    );

const _bgm = BgmPlan([
  BgmSegment(startUnit: 0, endUnit: 0, fit: BgmFit.cut, materials: [
    BgmMaterial(id: 1, name: '轻快垫乐', durationMs: 30000, previewUrl: null),
  ]),
]);

/// 提示条的重试按钮：页面上不止一条提示条，只认人声轨这一条
Finder get _retry => find.descendant(
      of: find.byKey(const Key('vocals-notice-banner')),
      matching: find.byKey(const Key('preview-audio-retry')),
    );

/// 改动日志的落点：工作台的每一次落盘都要记一笔，没有它就不写
/// （见 `gui_task_mutation.dart`）。一次性临时目录，测完就删
final _logDir = Directory.systemTemp.createTempSync('ishkafel_wb_test_');

void main() {
  tearDownAll(() {
    if (_logDir.existsSync()) _logDir.deleteSync(recursive: true);
  });

  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('ishkafel_vocals_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  /// 假分离器：按真实工具的行为造出两条 stem；[stderr] 非空则失败
  VocalSeparator separator({String? stderr}) => VocalSeparator(
        modelDir: Directory('${tempDir.path}/models'),
        run: (bin, args) async {
          if (stderr != null) return ProcessResult(1, 1, '', stderr);
          final outDir = args[args.indexOf('--output_dir') + 1];
          Directory(outDir).createSync(recursive: true);
          final stem = '${args.first.split('/').last.split('.').first}'
              '-${VocalSeparator.modelTag}';
          File('$outDir/$stem-人声.wav').writeAsStringSync('v');
          File('$outDir/$stem-背景.wav').writeAsStringSync('b');
          return ProcessResult(1, 0, '', '');
        },
      );

  AnalysisPipeline pipelineWith(VocalSeparator tool) => AnalysisPipeline(
        separator: tool,
        audio: AudioExtractor(run: (_, args) async {
          await File(args.last).writeAsBytes(Uint8List(16000));
          return ProcessResult(1, 0, '', '');
        }),
        silence: const SilenceDetector(),
        scenes: SceneDetector(run: (_, _) async => ProcessResult(1, 0, '', '')),
        asr: _FakeAsr(),
        splitter: _FakeSplitter(),
        builder: const SegmentationBuilder(snapper: BoundarySnapper()),
        repository: _Repo(),
        workDir: Directory('${tempDir.path}/work'),
      );

  AnalysisPipeline pipeline({String? stderr}) =>
      pipelineWith(separator(stderr: stderr));

  /// 一条铺了配乐、但人声轨指向空地址的任务——正是真机上那条
  RenewTask makeTask() {
    final source = File('${tempDir.path}/同一条片子.mp4')
      ..writeAsBytesSync(List<int>.filled(4096, 7));
    return RenewTask(
      id: '任务B',
      name: '滴露',
      sourcePath: source.path,
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 9, 4),
      updatedAt: DateTime.utc(2026, 9, 4),
      bgm: _bgm,
      // 先分析那条任务被删时，这个文件跟着走了
      vocalsPath: '${tempDir.path}/work/stems/任务A/早就被删掉了-人声.wav',
      units: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 5000,
          transcript: '第一句',
          shots: [Shot(startMs: 0, endMs: 5000)],
        ),
      ],
      videoInfo: const VideoInfo(
        width: 1080,
        height: 1920,
        duration: Duration(milliseconds: 5000),
        fps: 30,
        fileSizeBytes: 1,
      ),
    );
  }

  Future<(_Repo, RenewTask)> open(WidgetTester tester,
      {String? stderr, AnalysisPipeline? withPipeline}) async {
    final repo = _Repo();
    final task = makeTask();
    await repo.save(task);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
      dataDirProvider.overrideWithValue(_logDir),
        analysisPipelineProvider
            .overrideWithValue(withPipeline ?? pipeline(stderr: stderr)),
      ],
      child: MaterialApp(
        home: WorkbenchPage(
          task: task,
          playbackFactory: FakePlaybackController.new,
          mediaBuilder: _fakeMediaBuilder(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (repo, task);
  }

  testWidgets('人声轨指向空地址时，提示给的是「重新分离」而不是「重新分析」',
      (tester) async {
    await open(tester);

    expect(_retry, findsOneWidget, reason: '必须给一个真能解决问题的出口');
    expect(find.textContaining('重新分析'), findsNothing,
        reason: '命中缓存时重新分析走不到分离那一步，说了就是让人白忙');
  });

  testWidgets('点「重新分离」：补出这条任务自己的人声轨并落库，提示随之消失',
      (tester) async {
    final (repo, _) = await open(tester);

    await tester.tap(_retry);
    await tester.pumpAndSettle();

    final saved = await repo.findById('任务B');
    expect(saved!.vocalsPath, isNotNull);
    expect(File(saved.vocalsPath!).existsSync(), isTrue,
        reason: '存的路径必须真的有文件——指向空地址等于没有');
    expect(saved.vocalsPath, contains('任务B'),
        reason: '产物落在自己名下，不许借用别人的');
    expect(saved.backgroundPath, isNotNull, reason: '背景轨要一起记下来');
    expect(_retry, findsNothing, reason: '补上了就不该还挂着那条提示');
  });

  testWidgets('分离要十几秒，这段时间里界面必须说在分离', (tester) async {
    // 卡住分离：模拟真实工具跑十几秒的那段时间
    final gate = Completer<ProcessResult>();
    final held = VocalSeparator(
      modelDir: Directory('${tempDir.path}/models'),
      run: (bin, args) => gate.future,
    );
    await open(tester, withPipeline: pipelineWith(held));

    await tester.tap(_retry);
    await tester.pump();

    expect(find.textContaining('正在分离'), findsOneWidget,
        reason: '转圈不说话是不合格的——十几秒里人得知道软件在干什么');
    expect(_retry, findsNothing, reason: '正在跑就别再给一个按钮让人重复点');

    gate.complete(ProcessResult(1, 1, '', '模型下载失败'));
    await tester.pumpAndSettle();
  });

  testWidgets('机器上没装分离工具：把真实原因说出来，不许只当无事发生',
      (tester) async {
    await open(tester, stderr: 'command not found: audio-separator');

    await tester.tap(_retry);
    await tester.pumpAndSettle();

    expect(find.textContaining('未检测到人声分离工具'), findsOneWidget,
        reason: '他在等一个结果，失败就得让他看见原因');
  });

  testWidgets('分离工具没配上时不给重试出口——点了也是白点', (tester) async {
    final repo = _Repo();
    final task = makeTask();
    await repo.save(task);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [taskRepositoryProvider.overrideWithValue(repo), dataDirProvider.overrideWithValue(_logDir)],
      child: MaterialApp(
        home: WorkbenchPage(
          task: task,
          playbackFactory: FakePlaybackController.new,
          mediaBuilder: _fakeMediaBuilder(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(_retry, findsNothing);
    expect(find.textContaining('设置'), findsWidgets, reason: '要指路去装');
  });
}
