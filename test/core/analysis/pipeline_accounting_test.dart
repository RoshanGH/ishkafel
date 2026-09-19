import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_usage_scope.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/storage/task_log.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/analysis/silence_detector.dart';
import 'package:ishkafel/core/analysis/tag_vocabulary.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

class _Asr implements AsrProvider {
  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async =>
      const [AsrSentence(startMs: 0, endMs: 2000, text: '一句台词')];
}

class _Splitter implements SemanticSplitter {
  @override
  Future<List<UnitDraft>> split(List<AsrSentence> sentences) async => [
        for (final s in sentences)
          UnitDraft(startMs: s.startMs, endMs: s.endMs, transcript: s.text),
      ];
}

class _Vocab implements TagVocabularySource {
  @override
  Future<List<String>> vocabularyOf(int groupId) async => const ['促单'];
}

/// 打标时报一笔用量，模拟真实 Ark 客户端的行为
class _BillingTagger implements UnitTagger {
  static const model = 'doubao-seed-2-0-mini-260428';

  @override
  Future<ShotUnderstanding> understand({
    required String transcript,
    required List<TagDimension> dimensions,
    String? constraint,
  }) async {
    AiUsageScope.record(model: model, prompt: 1000, completion: 100);
    return const ShotUnderstanding(tags: ['促单']);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AnalysisPipeline _pipeline(Directory temp, FileTaskRepository repo,
        {UnitTagger? tagger}) =>
    AnalysisPipeline(
      audio: AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(Uint8List(16000));
        return ProcessResult(1, 0, '', '');
      }),
      silence: const SilenceDetector(),
      scenes: SceneDetector(run: (_, _) async => ProcessResult(1, 0, '', '')),
      asr: _Asr(),
      splitter: _Splitter(),
      builder: const SegmentationBuilder(snapper: BoundarySnapper()),
      repository: repo,
      workDir: Directory('${temp.path}/work'),
      unitTagger: tagger,
      vocabulary: tagger == null ? null : _Vocab(),
    );

RenewTask _task() => RenewTask(
      id: 'A1',
      name: 'a',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.analyzing,
      createdAt: DateTime.utc(2026, 8, 6),
      updatedAt: DateTime.utc(2026, 8, 6),
      unitTagGroups: const [TagGroupRef(id: 1, name: '台词层')],
      videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(seconds: 2),
          fps: 30,
          fileSizeBytes: 1),
    );

void main() {
  late Directory temp;
  late FileTaskRepository repo;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('ishkafel_acct_');
    repo = FileTaskRepository(temp);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('记下人真正等了多久——到「能进去干活」为止，不是等全部跑完', () async {
    final task = _task();
    await repo.save(task);

    final done = await _pipeline(temp, repo).analyze(task,
        by: ActorKind.agent, actor: 'Agent');

    expect(done.firstReadyMs, isNotNull);
    expect(done.firstReadyMs, greaterThanOrEqualTo(0));
    // 落库的那份也要有，首页读的是它
    expect((await repo.findById('A1'))!.firstReadyMs, done.firstReadyMs);
  });

  test('重新分析不覆盖首次等待时间——那是「首次」的定义', () async {
    final task = _task().copyWith(firstReadyMs: 12345);
    await repo.save(task);

    final done = await _pipeline(temp, repo).analyze(task,
        by: ActorKind.agent, actor: 'Agent');

    expect(done.firstReadyMs, 12345);
  });

  test('这一轮花的 AI 用量记到任务头上', () async {
    final task = _task();
    await repo.save(task);

    final done =
        await _pipeline(temp, repo, tagger: _BillingTagger()).analyze(task,
            by: ActorKind.agent, actor: 'Agent');

    expect(done.aiUsage.calls, 1);
    expect(done.aiUsage.promptTokens, 1000);
    expect(done.aiUsage.costYuan, isNotNull);
    expect((await repo.findById('A1'))!.aiUsage.calls, 1,
        reason: '不落库的话关掉应用花费就归零了');
  });

  test('花费是累加的——重新分析一次要加上去，不是覆盖', () async {
    final task = _task();
    await repo.save(task);

    await _pipeline(temp, repo, tagger: _BillingTagger()).analyze(task,
        by: ActorKind.agent, actor: 'Agent');
    final again = await repo.findById('A1');
    final done =
        await _pipeline(temp, repo, tagger: _BillingTagger()).analyze(again!,
            by: ActorKind.agent, actor: 'Agent');

    expect(done.aiUsage.calls, 2,
        reason: '用户在工作台里不停重打标，花费要一直涨');
    expect(done.aiUsage.promptTokens, 2000);
  });

  test('分析失败时交出去的是失败原因，不是结账过程中的错', () async {
    // 没落库、也没有 videoInfo：结账路径既找不到任务，也无账可记
    final task = RenewTask(
      id: 'missing',
      name: 'a',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.analyzing,
      createdAt: DateTime.utc(2026, 8, 6),
      updatedAt: DateTime.utc(2026, 8, 6),
    );

    await expectLater(
      _pipeline(temp, repo).analyze(task, by: ActorKind.agent, actor: 'Agent'),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('缺少视频元信息'))),
      reason: '结账再抛一个错会把真正的失败原因盖掉',
    );
  });
}
