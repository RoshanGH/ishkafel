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

/// 任务音频 PCM 的中间产物路径（分析管线与时间线波形共用同一份）。
///
/// 两处提取参数完全相同（16kHz 单声道 s16le），分开存会让同一份音频被写两
/// 遍：一条 5 分钟素材约 20MB，白白翻倍。共用后时间线可直接命中管线的产物，
/// 连第二次 ffmpeg 都省掉。
String analysisPcmPath(Directory workDir, String taskId) =>
    p.join(workDir.path, '$taskId.pcm');

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
    // 管线始终重新提取（-y 覆盖写）：它是这份 PCM 的权威产出方，
    // 复用可能残留的半截文件会让 ASR 拿到不完整音频
    final pcmPath = analysisPcmPath(workDir, task.id);

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
