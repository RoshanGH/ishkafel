import 'dart:io';
import 'package:path/path.dart' as p;
import '../ai/taggers.dart';
import '../ffmpeg/thumbnail_service.dart';
import '../log/app_log.dart';
import '../models/renew_task.dart';
import '../models/semantic_unit.dart';
import '../models/shot.dart';
import '../storage/task_repository.dart';
import 'audio_extractor.dart';
import 'providers.dart';
import 'scene_detector.dart';
import 'segmentation_builder.dart';
import 'silence_detector.dart';

/// 分析管线编排：PCM 提取 → 静音谷 → 场景检测 → ASR → 语义切分 → 吸附构树 → 打标 → 落库
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
  final UnitTagger? unitTagger;
  final ShotTagger? shotTagger;
  final ThumbnailService? thumbnails;
  final List<String> unitVocabulary;
  final List<String> shotVocabulary;

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
    this.unitTagger,
    this.shotTagger,
    this.thumbnails,
    this.unitVocabulary = const [],
    this.shotVocabulary = const [],
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

    final taggedUnits = await _tagUnits(task, units);

    final updated = task.copyWith(
      units: taggedUnits,
      status: RenewTaskStatus.awaitingCut,
      updatedAt: clock(),
      asrSentences: sentences,
    );
    await repository.save(updated);
    return updated;
  }

  /// 两层打标：台词语义单元（文本）+ 视觉镜头（代表帧）。打标失败不中断分析。
  Future<List<SemanticUnit>> _tagUnits(
      RenewTask task, List<SemanticUnit> units) async {
    final tagUnits = unitTagger != null && unitVocabulary.isNotEmpty;
    final tagShots = shotTagger != null &&
        shotVocabulary.isNotEmpty &&
        thumbnails != null;
    if (!tagUnits && !tagShots) return units;

    var shotIndex = 0;
    final result = <SemanticUnit>[];
    for (final unit in units) {
      var updatedUnit = unit;
      if (tagUnits) {
        try {
          final tags = await unitTagger!
              .tag(transcript: unit.transcript, vocabulary: unitVocabulary);
          updatedUnit = updatedUnit.copyWith(tags: tags);
        } catch (e) {
          AppLog.warn('单元 ${unit.index} 打标失败：$e');
        }
      }
      if (tagShots) {
        final shots = <Shot>[];
        for (final shot in updatedUnit.shots) {
          shots.add(await _tagShot(task, shot, shotIndex++));
        }
        updatedUnit = updatedUnit.copyWith(shots: shots);
      }
      result.add(updatedUnit);
    }
    return result;
  }

  Future<Shot> _tagShot(RenewTask task, Shot shot, int shotIndex) async {
    try {
      final midSeconds = (shot.startMs + shot.endMs) / 2 / 1000.0;
      final outPath = p.join(workDir.path, '${task.id}_shot$shotIndex.jpg');
      await thumbnails!.extractCover(
        videoPath: task.sourcePath,
        outPath: outPath,
        atSeconds: midSeconds,
      );
      final frameJpeg = await File(outPath).readAsBytes();
      final tags = await shotTagger!
          .tag(frameJpeg: frameJpeg, vocabulary: shotVocabulary);
      return shot.copyWith(tags: tags);
    } catch (e) {
      AppLog.warn('镜头（${shot.startMs}-${shot.endMs}）打标失败：$e');
      return shot;
    }
  }
}
