import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as p;
import '../ai/taggers.dart';
import '../ffmpeg/thumbnail_service.dart';
import '../log/app_log.dart';
import '../models/renew_task.dart';
import '../models/tag_group_ref.dart';
import '../models/semantic_unit.dart';
import '../models/shot.dart';
import '../storage/task_repository.dart';
import 'audio_extractor.dart';
import 'providers.dart';
import 'scene_detector.dart';
import 'segmentation_builder.dart';
import 'silence_detector.dart';
import 'tag_vocabulary.dart';

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

  /// 受控词表的来源。词表是**按任务**解析的（取决于该任务在新建向导里选的
  /// 两个标签组），所以这里注入的是「按组 id 查词表」的能力，而不是一份写死
  /// 的词表——后者等于所有任务共用一份，受控词表也就名存实亡。
  final TagVocabularySource? vocabulary;

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
    this.vocabulary,
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

  /// 两层打标：台词语义单元（文本）+ 视觉镜头（代表帧）。
  ///
  /// 词表按本任务选定的标签组现取（每个任务可能选不同的组），任何一层
  /// 取不到词表都只降级掉那一层，不中断整条分析——分析结果（切分）本身
  /// 仍然有价值，为了标签把它整条废掉不划算。
  Future<List<SemanticUnit>> _tagUnits(
      RenewTask task, List<SemanticUnit> units) async {
    final unitVocabulary = unitTagger == null
        ? const <String>[]
        : await _vocabularyFor(task.unitTagGroup, '台词语义单元');
    final shotVocabulary = (shotTagger == null || thumbnails == null)
        ? const <String>[]
        : await _vocabularyFor(task.shotTagGroup, '视觉镜头');

    final tagUnits = unitVocabulary.isNotEmpty;
    final tagShots = shotVocabulary.isNotEmpty;
    if (!tagUnits && !tagShots) return units;

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
      result.add(updatedUnit);
    }
    if (!tagShots) return result;
    return _tagAllShotsConcurrently(task, result, shotVocabulary);
  }

  /// 视觉镜头打标的并发上限。
  ///
  /// 真机实测单个镜头的视觉打标约 18 秒（抽代表帧 + 云端多模态推理），
  /// 32 个镜头串行就是近十分钟，用户只能对着「分析中」干等。并发上限取 4：
  /// 云端 API 有并发与配额限制，不能无上限地打出去。
  static const int _shotTaggingConcurrency = 4;

  /// 给全片的视觉镜头并发打标。
  ///
  /// 并发要跨单元而不是只在单元内部：真实素材里很多单元只包含一个镜头，
  /// 按单元并发等于没并发。结果按全局下标回填——按完成顺序收集会把标签
  /// 串到别的镜头上。
  Future<List<SemanticUnit>> _tagAllShotsConcurrently(
      RenewTask task, List<SemanticUnit> units, List<String> vocabulary) async {
    final flat = <({int unit, int shot})>[
      for (var u = 0; u < units.length; u++)
        for (var s = 0; s < units[u].shots.length; s++) (unit: u, shot: s),
    ];
    if (flat.isEmpty) return units;

    final tagged = List<Shot?>.filled(flat.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= flat.length) return;
        final at = flat[i];
        tagged[i] = await _tagShot(
            task, units[at.unit].shots[at.shot], i, vocabulary);
      }
    }

    await Future.wait(List.generate(
        math.min(_shotTaggingConcurrency, flat.length), (_) => worker()));

    final byUnit = <int, List<Shot>>{};
    for (var i = 0; i < flat.length; i++) {
      final at = flat[i];
      (byUnit[at.unit] ??= []).add(tagged[i] ?? units[at.unit].shots[at.shot]);
    }
    return [
      for (var u = 0; u < units.length; u++)
        units[u].copyWith(shots: byUnit[u] ?? units[u].shots),
    ];
  }

  /// 解析某一层的受控词表；未选组 / 无词表源 / 拉取失败 / 组内没标签
  /// 都返回空列表（=该层不打标），并各自记一条可排查的告警
  Future<List<String>> _vocabularyFor(TagGroupRef? group, String layer) async {
    final source = vocabulary;
    if (group == null || source == null) return const [];
    try {
      final words = await source.vocabularyOf(group.id);
      if (words.isEmpty) {
        AppLog.warn('$layer 标签组「${group.name}」内没有任何标签，跳过该层打标');
      }
      return words;
    } catch (e) {
      AppLog.warn('$layer 标签组「${group.name}」的词表拉取失败，跳过该层打标：$e');
      return const [];
    }
  }

  Future<Shot> _tagShot(RenewTask task, Shot shot, int shotIndex,
      List<String> shotVocabulary) async {
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
