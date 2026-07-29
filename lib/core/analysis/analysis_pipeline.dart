import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/renew_task.dart';
import '../storage/task_repository.dart';
import 'audio_extractor.dart';
import 'providers.dart';
import 'scene_detector.dart';
import 'segmentation_builder.dart';
import 'silence_detector.dart';

/// 分析管线编排：PCM 提取 → 静音谷 → 场景检测 → ASR → 语义切分 → 吸附构树 → 落库
class AnalysisPipeline {
  final AudioExtractor audio;
  final SilenceDetector silence;
  final SceneDetector scenes;
  final AsrProvider asr;
  final SemanticSplitter splitter;
  final SegmentationBuilder builder;
  final TaskRepository repository;
  final Directory workDir;
  final int sampleRate;
  final DateTime Function() clock;

  AnalysisPipeline({
    required this.audio,
    required this.silence,
    required this.scenes,
    required this.asr,
    required this.splitter,
    required this.builder,
    required this.repository,
    required this.workDir,
    this.sampleRate = 16000,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  Future<RenewTask> analyze(RenewTask task) async {
    final info = task.videoInfo;
    if (info == null) {
      throw StateError('任务 ${task.id} 缺少视频元信息，无法分析');
    }
    await workDir.create(recursive: true);
    final pcmPath = p.join(workDir.path, '${task.id}.pcm');

    final samples = await audio.extractSamples(
        videoPath: task.sourcePath,
        outPcmPath: pcmPath,
        sampleRate: sampleRate);
    final valleys = silence.detectValleyCenters(samples, sampleRate);
    final shotBounds = await scenes.detect(task.sourcePath);
    final sentences = await asr.transcribe(pcmPath);
    final drafts = await splitter.split(sentences);

    final units = builder.build(
      drafts: drafts,
      shotBoundaryMs: shotBounds,
      silenceValleyMs: valleys,
      videoDurationMs: info.duration.inMilliseconds,
      fps: info.fps,
    );

    final updated = task.copyWith(
      units: units,
      status: RenewTaskStatus.awaitingCut,
      updatedAt: clock(),
    );
    await repository.save(updated);
    return updated;
  }
}
