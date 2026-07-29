import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/analysis/silence_detector.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/video_info.dart';
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
          await File(args[args.length - 2])
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
}
