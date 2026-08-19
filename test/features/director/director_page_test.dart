import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/audio/tts_client.dart';
import 'package:ishkafel/core/script/line_voice_service.dart';
import 'package:ishkafel/core/script/script_transcriber.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/director/director_page.dart';
import 'package:ishkafel/features/director/director_providers.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_providers.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';

/// 编导台 M1：左栏脚本编辑 + 自动落盘 + 空态起步引导 + 从视频提取脚本。
/// 验收口径（实现分期）：建任务 → 写十行脚本 → 关掉重开不丢 → 行操作全可用。
class _MemoryRepo implements TaskRepository {
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

/// 假 ASR / 假断句：不碰任何真实服务
class _FakeAsr implements AsrProvider {
  final List<AsrSentence> sentences;
  _FakeAsr(this.sentences);
  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async => sentences;
}

/// 纯内存 stub：widget 测试跑在 fake-async 区，真实文件 IO 的 future
/// 永远不会完成（pumpAndSettle 会挂死），所以 extract 整个换掉。
/// 真实的抽音频→ASR→断句编排逻辑在 test/core/script/ 的普通单测里覆盖
class _StubTranscriber extends ScriptTranscriber {
  final List<String>? lines;
  final String? failWith;
  _StubTranscriber({this.lines, this.failWith})
      : super(
          audio: AudioExtractor(run: (_, _) async => ProcessResult(1, 0, '', '')),
          asr: _FakeAsr(const []),
          workDir: Directory.systemTemp,
        );

  @override
  Future<List<ScriptLine>> extract(String videoPath,
      {void Function(ScriptTranscribeStage stage)? onStage}) async {
    onStage?.call(ScriptTranscribeStage.transcribing);
    if (failWith != null) throw ScriptTranscribeException(failWith!);
    return [
      for (final text in lines ?? const ['第一句台词', '第二句台词'])
        ScriptLine.create(text: text),
    ];
  }
}

/// 纯内存配音服务：不碰 TTS 与文件系统
class _StubVoiceService extends LineVoiceService {
  final bool fail;
  _StubVoiceService({this.fail = false})
      : super(
          tts: const TtsClient(appId: 't', accessToken: 't'),
          outputDir: Directory.systemTemp,
          measureMs: (_) async => 0,
        );

  @override
  Future<LineVoiceover> generate({
    required String lineId,
    required String text,
    required String voiceId,
    int speechRate = 0,
  }) async {
    if (fail) throw const TtsException('连接语音合成服务超时，请检查网络后重试');
    return LineVoiceover(
      audioPath: '/tmp/fake.mp3',
      durationMs: 3200,
      sourceText: text.trim(),
      voiceId: voiceId,
      speechRate: speechRate,
    );
  }

  @override
  void deleteStale(LineVoiceover old) {}
}

RenewTask scriptTask({ScriptDoc? doc}) => RenewTask(
      id: 't1',
      seq: 7,
      name: '测试脚本',
      sourcePath: null,
      script: doc ?? ScriptDoc.empty(),
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 19),
      updatedAt: DateTime.utc(2026, 8, 19),
    );

ScriptDoc docWith(List<String> texts) {
  var doc = ScriptDoc.empty().updateText(0, texts.first);
  for (var i = 1; i < texts.length; i++) {
    doc = doc.insertAfter(i - 1, text: texts[i]);
  }
  return doc;
}

Widget wrap(TaskRepository repo, RenewTask task,
        {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        videoFilePickerProvider.overrideWithValue(() async => null),
        ...overrides,
      ],
      // 播放器注入空工厂：单测不碰 libmpv，中栏保持占位态
      child: MaterialApp(
          home: DirectorPage(task: task, playbackFactory: () => null)),
    );

/// hover 到某行上（拖柄/删除按钮都藏在 hover 里）
Future<TestGesture> hoverLine(WidgetTester tester, int index) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(
      tester.getCenter(find.byKey(ValueKey('script-line-$index'))));
  await tester.pumpAndSettle();
  return gesture;
}

/// 编导台是全屏工作页，默认测试窗口 800x600 连三栏都摆不下。
/// 统一用桌面全屏尺寸跑，跟真实使用一致
Future<void> pumpDirector(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
}

void main() {
  testWidgets('空脚本先回答「从哪里开始」：提取脚本与直接写两条路', (tester) async {
    await pumpDirector(tester, wrap(_MemoryRepo(), scriptTask()));
    await tester.pumpAndSettle();

    expect(find.textContaining('写下脚本'), findsOneWidget);
    expect(find.byKey(const ValueKey('director-guide-extract')), findsOneWidget);
    expect(find.byKey(const ValueKey('director-guide-write')), findsOneWidget);
    // 未配置 AI 服务时提取那条路禁用并说明原因，绝不是点了没反应
    expect(find.textContaining('需要先配置 AI 服务'), findsOneWidget);
    expect(find.text('推荐'), findsNothing,
        reason: '不可用的路径不该还挂着「推荐」');
    expect(find.text('画面行'), findsNothing,
        reason: '引导激活时右栏行工作台收敛，两套话语不打架');
  });

  testWidgets('点「直接开始写」后引导让位给预览舞台', (tester) async {
    await pumpDirector(tester, wrap(_MemoryRepo(), scriptTask()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('director-guide-write')));
    await tester.pumpAndSettle();

    expect(find.textContaining('在这里试片'), findsOneWidget,
        reason: '占位不许是一块死区域，要说明这里将来是什么');
    expect(find.text('00:00 / 00:00'), findsOneWidget,
        reason: '传输条骨架预告播放器的形状');
  });

  testWidgets('非空脚本直接进写作台：三栏 + 顶栏身份与自动保存说明', (tester) async {
    await pumpDirector(
        tester, wrap(_MemoryRepo(), scriptTask(doc: docWith(['开场白']))));
    await tester.pumpAndSettle();

    expect(find.text('脚本'), findsOneWidget);
    expect(find.textContaining('在这里试片'), findsOneWidget);
    expect(find.text('#7'), findsOneWidget, reason: '顶栏要带短编号');
    expect(find.text('编导台'), findsOneWidget);
    expect(find.textContaining('自动保存'), findsOneWidget,
        reason: '自动保存要说出来，用户才不会找「保存」按钮');
    expect(find.text('配音行'), findsOneWidget, reason: '右栏行工作台联动当前行');
  });

  testWidgets('写字自动变配音行，右栏徽标跟着变', (tester) async {
    await pumpDirector(tester, wrap(_MemoryRepo(), scriptTask()));
    await tester.pumpAndSettle();
    // 空脚本先是引导态，选「直接写」进入写作台
    await tester.tap(find.byKey(const ValueKey('director-guide-write')));
    await tester.pumpAndSettle();

    expect(find.text('画面行'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '世界上只有两种人');
    await tester.pumpAndSettle();

    expect(find.text('配音行'), findsOneWidget);
  });

  testWidgets('回车在当前行后插入新行，选中跳到新行', (tester) async {
    await pumpDirector(tester, wrap(_MemoryRepo(), scriptTask()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '第一句');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('script-line-1')), findsOneWidget);
    expect(find.textContaining('第 2 行'), findsOneWidget,
        reason: '回车后选中应落在新行，右栏跟着切换');
  });

  testWidgets('改动自动落盘（防抖后），不存在「保存」按钮', (tester) async {
    final repo = _MemoryRepo();
    await pumpDirector(tester, wrap(repo, scriptTask()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '要落盘的一句');
    await tester.pump(const Duration(seconds: 1));

    final saved = await repo.findById('t1');
    expect(saved?.script?.lines.first.text, '要落盘的一句');
    expect(find.text('保存'), findsNothing);
  });

  testWidgets('重开不丢：带已有脚本的任务进来，内容原样呈现', (tester) async {
    await pumpDirector(tester, wrap(
        _MemoryRepo(), scriptTask(doc: docWith(['上次写的', '还有这句']))));
    await tester.pumpAndSettle();

    expect(find.text('上次写的'), findsOneWidget);
    expect(find.text('还有这句'), findsOneWidget);
  });

  testWidgets('删除藏在 hover 里；最后一行不许删', (tester) async {
    final repo = _MemoryRepo();
    await pumpDirector(
        tester, wrap(repo, scriptTask(doc: docWith(['A', 'B']))));
    await tester.pumpAndSettle();

    // 未悬停时不该有一排叉常驻
    expect(find.byKey(const ValueKey('script-line-remove-1')), findsNothing);

    final gesture = await hoverLine(tester, 1);
    await tester.tap(find.byKey(const ValueKey('script-line-remove-1')));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('B'), findsNothing);

    // 只剩一行时 hover 也不给删除入口——脚本至少留一行可写
    await gesture
        .moveTo(tester.getCenter(find.byKey(const ValueKey('script-line-0'))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('script-line-remove-0')), findsNothing);
  });

  testWidgets('画面行可手填时长，落到 manualMs', (tester) async {
    final repo = _MemoryRepo();
    // 两行：一行台词一行空（画面行），选中画面行
    await pumpDirector(
        tester, wrap(repo, scriptTask(doc: docWith(['台词', '']))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('script-line-1')));
    await tester.pumpAndSettle();

    final field = find.byWidgetPredicate((w) =>
        w is TextFormField && w.key.toString().contains('manual-ms'));
    expect(field, findsOneWidget, reason: '画面行右栏要给手填时长入口');
    await tester.enterText(field, '3.5');
    await tester.pump(const Duration(seconds: 1));

    final saved = await repo.findById('t1');
    expect(saved?.script?.lines[1].manualMs, 3500);
  });

  testWidgets('从视频提取脚本：起步卡一路走通，行整体填充并落盘', (tester) async {
    final repo = _MemoryRepo();
    await pumpDirector(tester, wrap(repo, scriptTask(), overrides: [
      scriptTranscriberProvider
          .overrideWithValue(_StubTranscriber(lines: ['你好呀', '再见啦'])),
      videoFilePickerProvider.overrideWithValue(() async => '/v/参考片.mp4'),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('director-guide-extract')));
    await tester.pumpAndSettle();

    expect(find.text('你好呀'), findsOneWidget);
    expect(find.text('再见啦'), findsOneWidget);
    final saved = await repo.findById('t1');
    expect(saved?.script?.lines.map((l) => l.text), ['你好呀', '再见啦'],
        reason: '提取结果要立刻落盘');
  });

  testWidgets('脚本非空时提取先确认覆盖，取消则原样保留', (tester) async {
    final repo = _MemoryRepo();
    await pumpDirector(
        tester, wrap(repo, scriptTask(doc: docWith(['辛苦写的'])), overrides: [
      scriptTranscriberProvider.overrideWithValue(_StubTranscriber()),
      videoFilePickerProvider.overrideWithValue(() async => '/v/参考片.mp4'),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('director-extract-script')));
    await tester.pumpAndSettle();

    expect(find.textContaining('整体替换'), findsOneWidget,
        reason: '覆盖手写内容是破坏性操作，必须确认');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('辛苦写的'), findsOneWidget);
  });

  testWidgets('提取失败给原因和重试入口，不静默', (tester) async {
    final repo = _MemoryRepo();
    await pumpDirector(tester, wrap(repo, scriptTask(), overrides: [
      scriptTranscriberProvider.overrideWithValue(_StubTranscriber(
          failWith: '这条视频里没有识别到任何台词——请确认它有人声口播。')),
      videoFilePickerProvider.overrideWithValue(() async => '/v/参考片.mp4'),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('director-guide-extract')));
    await tester.pumpAndSettle();

    expect(find.textContaining('没有识别到任何台词'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
  group('配音节（M2）', () {
    testWidgets('未配置语音服务时按钮禁用；配置后选音色→生成→试听条与绿点',
        (tester) async {
      final repo = _MemoryRepo();
      await pumpDirector(
          tester, wrap(repo, scriptTask(doc: docWith(['你好呀']))));
      await tester.pumpAndSettle();

      // 默认没有 factory：按钮禁用（点了不该有任何反应）
      final btn = find.byKey(const ValueKey('inspector-generate-voice'));
      expect(tester.widget<FilledButton>(btn).onPressed, isNull);
    });

    testWidgets('生成一路走通：先弹音色选择，选完直接生成，状态点变绿',
        (tester) async {
      final repo = _MemoryRepo();
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: docWith(['你好呀'])), overrides: [
            lineVoiceFactoryProvider
                .overrideWithValue((_) => _StubVoiceService()),
          ]));
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(const ValueKey('inspector-generate-voice')));
      await tester.pumpAndSettle();
      // 没选过音色：先弹选择器
      expect(find.text('选择音色'), findsWidgets);
      await tester.tap(find
          .byKey(const ValueKey('voice-option-zh_female_vv_uranus_bigtts')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('就用这个'));
      await tester.pumpAndSettle();

      expect(find.text('3.2 秒'), findsOneWidget, reason: '试听条显示实际时长');
      expect(find.text('已生成'), findsOneWidget);
      final saved = await repo.findById('t1');
      expect(saved?.script?.lines.first.voiceover?.durationMs, 3200,
          reason: '配音产物要落盘');
    });

    testWidgets('改台词后状态变黄、旧配音仍可听、按钮变「重新生成」', (tester) async {
      final repo = _MemoryRepo();
      var doc = docWith(['你好呀']);
      doc = doc.setVoiceId(0, 'zh_female_vv_uranus_bigtts');
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
              audioPath: '/tmp/old.mp3',
              durationMs: 2000,
              sourceText: '你好呀',
              voiceId: 'zh_female_vv_uranus_bigtts',
              speechRate: 0));
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: doc), overrides: [
            lineVoiceFactoryProvider
                .overrideWithValue((_) => _StubVoiceService()),
          ]));
      await tester.pumpAndSettle();
      expect(find.text('已生成'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '你好呀改了');
      await tester.pumpAndSettle();

      expect(find.text('已过期'), findsOneWidget);
      expect(find.textContaining('这是旧配音'), findsOneWidget);
      expect(find.text('重新生成'), findsOneWidget);
      expect(find.text('2.0 秒'), findsOneWidget, reason: '旧配音仍可试听');
    });

    testWidgets('生成失败给中文原因，不静默', (tester) async {
      final repo = _MemoryRepo();
      var doc = docWith(['你好呀']);
      doc = doc.setVoiceId(0, 'zh_female_vv_uranus_bigtts');
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: doc), overrides: [
            lineVoiceFactoryProvider
                .overrideWithValue((_) => _StubVoiceService(fail: true)),
          ]));
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(const ValueKey('inspector-generate-voice')));
      await tester.pumpAndSettle();

      expect(find.textContaining('配音生成失败'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5)); // 等 SnackBar 收场
    });
  });
}
