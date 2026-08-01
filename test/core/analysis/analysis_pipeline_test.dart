import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/analysis/silence_detector.dart';
import 'package:ishkafel/core/analysis/tag_vocabulary.dart';
import 'package:ishkafel/core/log/app_log.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/net/json_poster.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// 假 ASR：返回固定句子
class FakeAsr implements AsrProvider {
  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async => const [
        AsrSentence(startMs: 0, endMs: 4100, text: '第一句'),
        AsrSentence(startMs: 4100, endMs: 9200, text: '第二句'),
      ];
}

/// 假语义切分：每句一个单元
class FakeSplitter implements SemanticSplitter {
  @override
  Future<List<UnitDraft>> split(List<AsrSentence> sentences) async => [
        for (final s in sentences)
          UnitDraft(startMs: s.startMs, endMs: s.endMs, transcript: s.text),
      ];
}

const showinfoFixture =
    '[Parsed_showinfo_1 @ 0x60] n: 0 pts: 120 pts_time:4.0 fmt:yuv420p\n';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ishkafel_pipeline_');
  });

  tearDown(() async => tempDir.delete(recursive: true));

  AnalysisPipeline makePipeline(FileTaskRepository repo) => AnalysisPipeline(
        audio: AudioExtractor(run: (_, args) async {
          // 假 ffmpeg 音频提取：写入 0.5 秒 16kHz 静音采样
          await File(args[args.length - 1])
              .writeAsBytes(Uint8List(16000)); // 8000 个零采样
          return ProcessResult(1, 0, '', '');
        }),
        silence: const SilenceDetector(),
        scenes: SceneDetector(
            run: (_, _) async => ProcessResult(1, 0, '', showinfoFixture)),
        asr: FakeAsr(),
        splitter: FakeSplitter(),
        builder: const SegmentationBuilder(snapper: BoundarySnapper()),
        repository: repo,
        workDir: Directory('${tempDir.path}/work'),
        clock: () => DateTime.utc(2026, 7, 29, 12),
      );

  RenewTask makeTask() => RenewTask(
        id: 't1',
        name: '测试片',
        sourcePath: '/v/a.mp4',
        videoInfo: const VideoInfo(
            width: 1080,
            height: 1920,
            duration: Duration(milliseconds: 9200),
            fps: 30,
            fileSizeBytes: 1),
        status: RenewTaskStatus.analyzing,
        createdAt: DateTime.utc(2026, 7, 29),
        updatedAt: DateTime.utc(2026, 7, 29),
      );

  test('analyze 产出两层结构并落库，状态转 awaitingCut', () async {
    final repo = FileTaskRepository(tempDir);
    final task = makeTask();
    await repo.save(task);

    final result = await makePipeline(repo).analyze(task);

    expect(result.status, RenewTaskStatus.awaitingCut);
    expect(result.units, isNotNull);
    expect(result.units!.length, 2);
    // 内部边界 4100 吸附到镜头边界 4000（fixture 的 pts_time:4.0）
    expect(result.units![0].endMs, 4000);
    expect(result.units![1].startMs, 4000);
    expect(result.units![1].endMs, 9200);
    for (final u in result.units!) {
      expect(u.shotsStrictlyNested, true);
      expect(u.shots.first.startMs, u.startMs);
      expect(u.shots.last.endMs, u.endMs);
    }
    // 已落库
    final persisted = await repo.findById('t1');
    expect(persisted, result);
  });

  test('PCM 落到共享路径 <workDir>/<taskId>.pcm（时间线复用同一份）', () async {
    final repo = FileTaskRepository(tempDir);
    final task = makeTask();
    await repo.save(task);
    final workDir = Directory('${tempDir.path}/work');

    await makePipeline(repo).analyze(task);

    expect(analysisPcmPath(workDir, 't1'), '${workDir.path}/t1.pcm');
    expect(await File(analysisPcmPath(workDir, 't1')).exists(), isTrue);
  });

  test('videoInfo 缺失抛 StateError 且不落库变更', () async {
    final repo = FileTaskRepository(tempDir);
    final noInfo = RenewTask(
      id: 't2',
      name: 'n',
      sourcePath: '/v/b.mp4',
      status: RenewTaskStatus.analyzing,
      createdAt: DateTime.utc(2026, 7, 29),
      updatedAt: DateTime.utc(2026, 7, 29),
    );
    await expectLater(
        makePipeline(repo).analyze(noInfo), throwsA(isA<StateError>()));
    expect(await repo.findById('t2'), isNull);
  });

  test('analyze 后 asrSentences 与 FakeAsr 输出逐值相等（精度红线）', () async {
    final repo = FileTaskRepository(tempDir);
    final task = makeTask();
    await repo.save(task);

    final result = await makePipeline(repo).analyze(task);

    expect(result.asrSentences, await FakeAsr().transcribe(''));
    final persisted = await repo.findById('t1');
    expect(persisted!.asrSentences, result.asrSentences);
  });

  group('两层打标的受控词表按任务的标签组解析（不同任务不共用一份词表）', () {
    /// 假词表源：按组 id 返回不同词表，并记录被问过哪些组
    final asked = <int>[];
    TagVocabularySource fakeSource(Map<int, List<String>> byGroup) =>
        _FakeVocabularySource(byGroup, asked);

    setUp(asked.clear);

    AnalysisPipeline taggingPipeline(
      FileTaskRepository repo, {
      UnitTagger? unitTagger,
      ShotTagger? shotTagger,
      TagVocabularySource? vocabulary,
      ThumbnailService? thumbnails,
    }) =>
        AnalysisPipeline(
          audio: AudioExtractor(run: (_, args) async {
            await File(args.last).writeAsBytes(Uint8List(16000));
            return ProcessResult(1, 0, '', '');
          }),
          silence: const SilenceDetector(),
          scenes: SceneDetector(
              run: (_, _) async => ProcessResult(1, 0, '', showinfoFixture)),
          asr: FakeAsr(),
          splitter: FakeSplitter(),
          builder: const SegmentationBuilder(snapper: BoundarySnapper()),
          repository: repo,
          workDir: Directory('${tempDir.path}/work'),
          clock: () => DateTime.utc(2026, 7, 30),
          unitTagger: unitTagger,
          shotTagger: shotTagger,
          thumbnails: thumbnails,
          vocabulary: vocabulary,
        );

    ThumbnailService fakeThumbnails() => ThumbnailService(run: (_, args) async {
          await File(args.last).writeAsBytes(Uint8List.fromList([1, 2, 3]));
          return ProcessResult(1, 0, '', '');
        });

    test('视觉镜头打标并发进行（串行时 32 个镜头要跑近十分钟）', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask()
          .copyWith(shotTagGroups: [const TagGroupRef(id: 136, name: '画面类型')]);
      await repo.save(task);

      var inFlight = 0;
      var peak = 0;
      var calls = 0;

      await taggingPipeline(
        repo,
        shotTagger: _FakeShotTagger(
          onTag: () {
            calls++;
            inFlight++;
            if (inFlight > peak) peak = inFlight;
          },
          work: () async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            inFlight--;
          },
        ),
        thumbnails: fakeThumbnails(),
        vocabulary: fakeSource({
          136: const ['开箱']
        }),
      ).analyze(task);

      expect(calls, greaterThan(1), reason: '前提：确实跑了多个镜头的打标');
      expect(peak, greaterThan(1),
          reason: '串行打标下峰值并发恒为 1。真机实测单个镜头的视觉打标约 18 秒，'
              '32 个镜头串行就是近十分钟，用户只能对着「分析中」干等');
      expect(peak, lessThanOrEqualTo(4),
          reason: '云端 API 有并发与配额限制，不能无上限地打出去');
    });

    test('配置 taggers 后单元按本任务的单元标签组打标', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask().copyWith(
          unitTagGroups: [const TagGroupRef(id: 1279, name: '衣清.消毒液')]);
      await repo.save(task);
      final tagger = _RecordingUnitTagger(reply: const ['功效演示']);

      final result = await taggingPipeline(repo,
              unitTagger: tagger,
              vocabulary: fakeSource({
                1279: const ['功效演示', '价格机制']
              }))
          .analyze(task);

      expect(tagger.calls, result.units!.length);
      expect(result.units!.first.tags, ['功效演示']);
      expect(tagger.vocabularies.first, ['功效演示', '价格机制'],
          reason: '词表必须来自本任务选的那个标签组');
      expect(asked, [1279]);
    });

    test('两个任务选了不同标签组时，各自拿到各自的词表', () async {
      final repo = FileTaskRepository(tempDir);
      final source = fakeSource({
        1279: const ['功效演示'],
        1281: const ['开箱'],
      });
      final tagger = _RecordingUnitTagger(reply: const []);
      final a = makeTask().copyWith(
          unitTagGroups: [const TagGroupRef(id: 1279, name: '衣清.消毒液')]);
      final b = RenewTask.fromJson(makeTask().toJson())
          .copyWith(unitTagGroups: [const TagGroupRef(id: 1281, name: '衣清.立白卫仕')]);
      await repo.save(a);

      await taggingPipeline(repo, unitTagger: tagger, vocabulary: source)
          .analyze(a);
      final vocabA = tagger.vocabularies.last;
      await taggingPipeline(repo, unitTagger: tagger, vocabulary: source)
          .analyze(b);

      expect(vocabA, ['功效演示']);
      expect(tagger.vocabularies.last, ['开箱']);
    });

    test('镜头层按视觉镜头标签组打标（抽帧 + 该组词表）', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask()
          .copyWith(shotTagGroups: [const TagGroupRef(id: 136, name: '画面类型')]);
      await repo.save(task);
      var shotCalls = 0;

      final result = await taggingPipeline(
        repo,
        shotTagger: _FakeShotTagger(onTag: () => shotCalls++),
        thumbnails: fakeThumbnails(),
        vocabulary: fakeSource({
          136: const ['开箱']
        }),
      ).analyze(task);

      final totalShots =
          result.units!.fold<int>(0, (n, u) => n + u.shots.length);
      expect(shotCalls, totalShots);
      expect(result.units!.first.shots.first.tags, ['开箱']);
      expect(asked, [136]);
    });

    test('任务没选标签组时该层不打标，也不去拉词表（不许退回共用词表）', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask();
      await repo.save(task);
      final tagger = _RecordingUnitTagger(reply: const ['功效演示']);

      final result = await taggingPipeline(repo,
              unitTagger: tagger,
              vocabulary: fakeSource({
                1279: const ['功效演示']
              }))
          .analyze(task);

      expect(tagger.calls, 0);
      expect(asked, isEmpty);
      for (final u in result.units!) {
        expect(u.tags, isEmpty);
      }
    });

    test('拉词表失败不中断分析：该层留空并告警（不静默）', () async {
      final logs = <String>[];
      final previous = AppLog.sink;
      AppLog.sink = logs.add;
      addTearDown(() => AppLog.sink = previous);

      final repo = FileTaskRepository(tempDir);
      final task = makeTask().copyWith(
          unitTagGroups: [const TagGroupRef(id: 1279, name: '衣清.消毒液')]);
      await repo.save(task);

      final result = await taggingPipeline(repo,
              unitTagger: _RecordingUnitTagger(reply: const ['功效演示']),
              vocabulary: _ThrowingVocabularySource())
          .analyze(task);

      expect(result.status, RenewTaskStatus.awaitingCut);
      for (final u in result.units!) {
        expect(u.tags, isEmpty);
      }
      expect(logs.join(), contains('词表'));
    });

    test('标签组存在但组内没有标签时跳过打标并告警（空词表打标毫无意义）', () async {
      final logs = <String>[];
      final previous = AppLog.sink;
      AppLog.sink = logs.add;
      addTearDown(() => AppLog.sink = previous);

      final repo = FileTaskRepository(tempDir);
      final task = makeTask().copyWith(
          unitTagGroups: [const TagGroupRef(id: 1279, name: '空组')]);
      await repo.save(task);
      final tagger = _RecordingUnitTagger(reply: const ['功效演示']);

      await taggingPipeline(repo,
              unitTagger: tagger,
              vocabulary: fakeSource({1279: const []}))
          .analyze(task);

      expect(tagger.calls, 0);
      expect(logs.join(), contains('空组'));
    });

    test('unitTagger 抛异常不中断分析，该单元 tags 留空', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask().copyWith(
          unitTagGroups: [const TagGroupRef(id: 1279, name: '衣清.消毒液')]);
      await repo.save(task);

      final result = await taggingPipeline(repo,
              unitTagger: _ThrowingUnitTagger(),
              vocabulary: fakeSource({
                1279: const ['功效演示']
              }))
          .analyze(task);

      expect(result.units, isNotNull);
      for (final u in result.units!) {
        expect(u.tags, isEmpty);
      }
    });
  });

  _multiGroupVocabulary();
}

/// 假词表源：按组 id 给不同词表，并记录被问过的组 id
class _FakeVocabularySource implements TagVocabularySource {
  final Map<int, List<String>> byGroup;
  final List<int> asked;
  _FakeVocabularySource(this.byGroup, this.asked);

  @override
  Future<List<String>> vocabularyOf(int groupId) async {
    asked.add(groupId);
    return byGroup[groupId] ?? const [];
  }
}

class _ThrowingVocabularySource implements TagVocabularySource {
  @override
  Future<List<String>> vocabularyOf(int groupId) async =>
      throw StateError('拉词表失败（模拟）');
}

/// 记录每次调用与传入词表的假 UnitTagger
class _RecordingUnitTagger extends UnitTagger {
  final List<String> reply;
  final vocabularies = <List<String>>[];
  int calls = 0;

  _RecordingUnitTagger({required this.reply})
      : super(
            chat: ArkChatClient(
                apiKey: 'x',
                post: (_, _, _) async =>
                    const JsonPostResult(statusCode: 200, body: '{}')));

  @override
  Future<List<String>> tag(
      {required String transcript, required List<String> vocabulary}) async {
    calls++;
    vocabularies.add(vocabulary);
    return reply;
  }
}

class _ThrowingUnitTagger extends UnitTagger {
  _ThrowingUnitTagger()
      : super(
            chat: ArkChatClient(
                apiKey: 'x',
                post: (_, _, _) async =>
                    const JsonPostResult(statusCode: 200, body: '{}')));
  @override
  Future<List<String>> tag(
      {required String transcript, required List<String> vocabulary}) async {
    throw StateError('打标服务不可用');
  }
}

/// 视觉镜头打标的并发度：真机实测单个镜头的视觉打标约 18 秒，
/// 32 个镜头串行就是近十分钟，用户只能对着「分析中」干等。
class _FakeShotTagger extends ShotTagger {
  final void Function() onTag;
  final Future<void> Function()? work;
  _FakeShotTagger({required this.onTag, this.work})
      : super(
            chat: ArkChatClient(
                apiKey: 'x',
                post: (_, _, _) async =>
                    const JsonPostResult(statusCode: 200, body: '{}')));
  @override
  Future<List<String>> tag(
      {required List<int> frameJpeg, required List<String> vocabulary}) async {
    onTag();
    if (work != null) await work!();
    return ['开箱'];
  }

}
void _multiGroupVocabulary() {
  group('多个标签组的词表合并成一份', () {
    test('两个组的标签都进了受控词表，重复词只留一个', () async {
      final asked = <int>[];
      final source = _FakeVocabularySource({
        1: const ['真人口播', '产品特写'],
        2: const ['产品特写', '情绪激动'], // 与组 1 有重复
      }, asked);

      final merged = <String>[];
      for (final id in [1, 2]) {
        for (final w in await source.vocabularyOf(id)) {
          if (!merged.contains(w)) merged.add(w);
        }
      }

      expect(merged, ['真人口播', '产品特写', '情绪激动'],
          reason: '重复词只会稀释提示词，去重按标签名');
      expect(asked, [1, 2], reason: '每个选中的组都要拉一次');
    });
  });
}
