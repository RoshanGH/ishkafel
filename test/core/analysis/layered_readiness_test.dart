import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/net/json_poster.dart';
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
  Future<List<UnitDraft>> split(List<AsrSentence> s) async => [
        for (final x in s)
          UnitDraft(startMs: x.startMs, endMs: x.endMs, transcript: x.text),
      ];
}

class _Vocab implements TagVocabularySource {
  @override
  Future<List<String>> vocabularyOf(int groupId) async => const ['促单'];
}

/// 打标卡在这里，直到测试放行——这样才能看出「切分就绪」有没有先落库
class _SlowTagger extends UnitTagger {
  final Completer<void> gate;
  _SlowTagger(this.gate)
      : super(
            chat: ArkChatClient(
                apiKey: 'x',
                post: (_, _, _) async =>
                    const JsonPostResult(statusCode: 200, body: '{}')));

  @override
  Future<ShotUnderstanding> understand({
    required String transcript,
    required List<TagDimension> dimensions,
    String? constraint,
  }) async {
    await gate.future;
    return const ShotUnderstanding(tags: ['促单']);
  }
}

void main() {
  test('切分一好就落库放人进去，打标在后台补', () async {
    final temp = Directory.systemTemp.createTempSync('ishkafel_layer_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final repo = FileTaskRepository(temp);
    final gate = Completer<void>();

    final task = RenewTask(
      id: 'L1',
      name: 'a',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.analyzing,
      createdAt: DateTime.utc(2026, 8, 5),
      updatedAt: DateTime.utc(2026, 8, 5),
      unitTagGroups: const [TagGroupRef(id: 1, name: '台词层')],
      videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(seconds: 2),
          fps: 30,
          fileSizeBytes: 1),
    );
    await repo.save(task);

    RenewTask? readyAt;
    final done = AnalysisPipeline(
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
      unitTagger: _SlowTagger(gate),
      vocabulary: _Vocab(),
      clock: () => DateTime.utc(2026, 8, 5),
    ).analyze(task,
        by: ActorKind.agent, actor: 'Agent', onUnitsReady: (r) => readyAt = r);

    // 打标还卡着，但切分应该已经落库、状态已经放出来了
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final mid = await repo.findById('L1');

    expect(readyAt, isNotNull, reason: '要通知上层「可以进去干活了」');
    expect(mid!.status, RenewTaskStatus.ready,
        reason: '还挂在「分析中」的话，用户根本点不进去');
    expect(mid.units, isNotNull);
    expect(mid.units!.first.tags, isEmpty, reason: '这一刻标签还没打，是正常的');

    gate.complete();
    final finished = await done;
    expect(finished.units!.first.tags, ['促单'], reason: '后台补完要落库');
  });
}
