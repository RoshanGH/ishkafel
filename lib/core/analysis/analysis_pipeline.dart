import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as p;
import '../ai/taggers.dart';
import '../ffmpeg/thumbnail_service.dart';
import '../log/app_log.dart';
import '../models/renew_task.dart';
import '../models/tag_group_ref.dart';
import '../models/tag_trace.dart';
import '../models/semantic_unit.dart';
import '../models/shot.dart';
import '../storage/task_repository.dart';
import 'analysis_progress.dart';
import 'audio_extractor.dart';
import 'providers.dart';
import 'scene_detector.dart';
import 'segmentation_builder.dart';
import 'shot_frame_sampler.dart';
import 'shot_boundary_finder.dart';
import 'silence_detector.dart';
import 'tag_vocabulary.dart';

/// 任务音频 PCM 的中间产物路径（分析管线与时间线波形共用同一份）。
///
/// 两处提取参数完全相同（16kHz 单声道 s16le），分开存会让同一份音频被写两
/// 遍：一条 5 分钟素材约 20MB，白白翻倍。共用后时间线可直接命中管线的产物，
/// 连第二次 ffmpeg 都省掉。
String analysisPcmPath(Directory workDir, String taskId) =>
    p.join(workDir.path, '$taskId.pcm');

/// 送去做视觉理解的帧高度。
///
/// 多帧时分辨率是 token 消耗的主因，而判断「画面是什么」不需要原始 1080p；
/// 竖屏 9:16 下 512 高约合 288 宽，主体与场景仍然清晰可辨。
const int understandingFrameHeight = 512;

/// 分析管线编排：PCM 提取 → 静音谷 → 场景检测 → ASR → 语义切分 → 吸附构树 → 打标 → 落库
class AnalysisPipeline {
  final AudioExtractor audio;
  final SilenceDetector silence;
  final SceneDetector scenes;

  /// 视觉镜头切点求解（双判据 + 灰区画面复核）。null 时回退到 [scenes] 的
  /// 单一 scene 阈值——旧口径，只抓得住最剧烈的硬切，见
  /// docs/plans/2026-08-01-镜头切分优化.md
  final ShotBoundaryFinder? shotBoundaries;
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
    this.shotBoundaries,
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

  /// 上报一步进度。
  ///
  /// 回调抛异常只记日志：进度只是「说一声」，因为没人听就把整条分析废掉，
  /// 等于让十几分钟的计算白跑。
  void _report(AnalysisProgressSink? sink, AnalysisStage stage,
      {int? done, int? total}) {
    if (sink == null) return;
    try {
      sink(AnalysisProgress(stage: stage, done: done, total: total));
    } catch (e) {
      AppLog.warn('分析进度回调抛异常（已忽略）：$e');
    }
  }

  /// [onProgress] 逐次传入而不是挂在实例上：管线是全应用共享的单例，
  /// 挂在实例上会让所有任务的进度都涌向同一个回调，还分不清是谁的。
  Future<RenewTask> analyze(RenewTask task,
      {AnalysisProgressSink? onProgress}) async {
    final info = task.videoInfo;
    if (info == null) {
      throw StateError('任务 ${task.id} 缺少视频元信息，无法分析');
    }
    await workDir.create(recursive: true);
    // 管线始终重新提取（-y 覆盖写）：它是这份 PCM 的权威产出方，
    // 复用可能残留的半截文件会让 ASR 拿到不完整音频
    final pcmPath = analysisPcmPath(workDir, task.id);

    _report(onProgress, AnalysisStage.extractingAudio);
    final samples = await audio.extractSamples(
        videoPath: task.sourcePath,
        outPcmPath: pcmPath,
        sampleRate: sampleRate);
    final valleys = silence.detectValleyCenters(samples, sampleRate);

    _report(onProgress, AnalysisStage.detectingScenes);
    final shotBounds = await _detectShotBoundaries(task, info.fps);

    _report(onProgress, AnalysisStage.transcribing);
    final sentences = await asr.transcribe(pcmPath);

    _report(onProgress, AnalysisStage.splitting);
    final drafts = await splitter.split(sentences);

    _report(onProgress, AnalysisStage.building);
    final units = builder.build(
      drafts: drafts,
      shotBoundaryMs: shotBounds,
      silenceValleyMs: valleys,
      videoDurationMs: info.duration.inMilliseconds,
      fps: info.fps,
    );

    final taggedUnits = await _tagUnits(task, _withBoundaryTrace(units), onProgress);

    final updated = task.copyWith(
      units: taggedUnits,
      status: RenewTaskStatus.awaitingCut,
      updatedAt: clock(),
      asrSentences: sentences,
    );
    await repository.save(updated);
    return updated;
  }

  /// 求视觉镜头切点。新链路（双判据 + 画面复核）失败时退回旧的单一阈值
  /// 检测——切分结果本身仍有价值，为了「切得更准」把整条分析废掉不划算。
  Future<List<int>> _detectShotBoundaries(RenewTask task, double fps) async {
    final finder = shotBoundaries;
    if (finder == null) return scenes.detect(task.sourcePath);
    try {
      return await finder.find(
          videoPath: task.sourcePath, taskId: task.id, fps: fps);
    } catch (e) {
      AppLog.warn('镜头切点检测失败，退回基础场景检测：$e');
      return scenes.detect(task.sourcePath);
    }
  }

  /// 把切点判定明细贴到镜头上：每个镜头的**起点**就是那一刀，画面差异分数
  /// 与「直接确认 / 灰区经画面复核保留」都记在这里，事后能回看这一刀的依据。
  List<SemanticUnit> _withBoundaryTrace(List<SemanticUnit> units) {
    final details = ShotBoundaryFinder.lastDetails;
    if (details.isEmpty) return units;
    BoundaryTrace? traceAt(int ms) {
      final c = details[ms];
      if (c == null) return null;
      return BoundaryTrace(
        sceneScore: c.sceneScore,
        histDistance: c.histDistance,
        decision: c.isConfirmed ? 'confirmed' : 'reviewed',
      );
    }

    return List.unmodifiable([
      for (final u in units)
        u.copyWith(shots: [
          for (final s in u.shots)
            if (traceAt(s.startMs) case final t?) s.copyWith(boundaryTrace: t) else s,
        ]),
    ]);
  }

  /// 两层打标：台词语义单元（文本）+ 视觉镜头（代表帧）。
  ///
  /// 词表按本任务选定的标签组现取（每个任务可能选不同的组），任何一层
  /// 取不到词表都只降级掉那一层，不中断整条分析——分析结果（切分）本身
  /// 仍然有价值，为了标签把它整条废掉不划算。
  Future<List<SemanticUnit>> _tagUnits(RenewTask task,
      List<SemanticUnit> units, AnalysisProgressSink? onProgress) async {
    final unitVocabulary = unitTagger == null
        ? const <String>[]
        : await _vocabularyFor(task.unitTagGroups, '台词语义单元');
    final shotVocabulary = (shotTagger == null || thumbnails == null)
        ? const <String>[]
        : await _vocabularyFor(task.shotTagGroups, '视觉镜头');

    final tagUnits = unitVocabulary.isNotEmpty;
    final tagShots = shotVocabulary.isNotEmpty;
    if (!tagUnits && !tagShots) return units;

    final result = <SemanticUnit>[];
    if (tagUnits) _report(onProgress, AnalysisStage.taggingUnits, done: 0, total: units.length);
    for (final unit in units) {
      var updatedUnit = unit;
      if (tagUnits) {
        try {
          final r = await unitTagger!.understand(
              transcript: unit.transcript, vocabulary: unitVocabulary);
          updatedUnit = updatedUnit.copyWith(
            tags: r.tags,
            trace: TagTrace(
              textInput: unit.transcript,
              vocabularyGroups: [for (final g in task.unitTagGroups) g.name],
              vocabularySize: unitVocabulary.length,
              rawReply: r.rawReply,
              at: clock(),
            ),
          );
        } catch (e) {
          AppLog.warn('单元 ${unit.index} 打标失败：$e');
        }
      }
      result.add(updatedUnit);
      if (tagUnits) {
        _report(onProgress, AnalysisStage.taggingUnits,
            done: result.length, total: units.length);
      }
    }
    if (!tagShots) return result;
    return _tagAllShotsConcurrently(task, result, shotVocabulary, onProgress);
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
      RenewTask task,
      List<SemanticUnit> units,
      List<String> vocabulary,
      AnalysisProgressSink? onProgress) async {
    final flat = <({int unit, int shot})>[
      for (var u = 0; u < units.length; u++)
        for (var s = 0; s < units[u].shots.length; s++) (unit: u, shot: s),
    ];
    if (flat.isEmpty) return units;

    final tagged = List<Shot?>.filled(flat.length, null);
    var next = 0;
    // 完成计数与回填下标是两回事：并发下第 5 个开工的可能第 1 个结束，
    // 用下标当进度会让数字来回跳
    var completed = 0;
    _report(onProgress, AnalysisStage.taggingShots, done: 0, total: flat.length);

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= flat.length) return;
        final at = flat[i];
        tagged[i] = await _tagShot(
            task, units[at.unit].shots[at.shot], i, vocabulary);
        _report(onProgress, AnalysisStage.taggingShots,
            done: ++completed, total: flat.length);
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
  /// 把选中的若干标签组合并成一份受控词表。
  ///
  /// 合并而不是逐组各打一轮：一个单元/镜头本来就该同时有几个维度的标签，
  /// 逐组打会让 API 调用次数按组数翻倍（镜头打标已经是最慢的一步）。
  /// 去重按标签名——不同组里出现同名标签是常事，重复词只会稀释提示词。
  ///
  /// 单个组拉失败只跳过它，其余组照常用：为一个组把整层打标废掉不划算。
  Future<List<String>> _vocabularyFor(
      List<TagGroupRef> groups, String layer) async {
    final source = vocabulary;
    if (groups.isEmpty || source == null) return const [];
    final merged = <String>[];
    for (final group in groups) {
      try {
        final words = await source.vocabularyOf(group.id);
        if (words.isEmpty) {
          AppLog.warn('$layer 标签组「${group.name}」内没有任何标签');
        }
        for (final w in words) {
          if (!merged.contains(w)) merged.add(w);
        }
      } catch (e) {
        AppLog.warn('$layer 标签组「${group.name}」的词表拉取失败，跳过这个组：$e');
      }
    }
    if (merged.isEmpty) {
      AppLog.warn('$layer 没有可用的受控词表，跳过该层打标');
    }
    return List.unmodifiable(merged);
  }

  /// 视觉理解一个镜头：按秒采样多帧 → 一次调用同时拿标签与画面描述。
  ///
  /// 缩到 512 宽再送：多帧时分辨率是 token 消耗的主因，而判断「画面是什么」
  /// 不需要原始 1080p。
  Future<Shot> _tagShot(RenewTask task, Shot shot, int shotIndex,
      List<String> shotVocabulary) async {
    try {
      final at = ShotFrameSampler.sampleAt(
          startMs: shot.startMs, endMs: shot.endMs);
      final frames = <List<int>>[];
      final paths = <String>[];
      for (var i = 0; i < at.length; i++) {
        final outPath =
            p.join(workDir.path, '${task.id}_shot${shotIndex}_$i.jpg');
        paths.add(outPath);
        await thumbnails!.extractCover(
          videoPath: task.sourcePath,
          outPath: outPath,
          atSeconds: at[i] / 1000.0,
          height: understandingFrameHeight,
        );
        frames.add(await File(outPath).readAsBytes());
      }
      final r = await shotTagger!
          .understand(frames: frames, vocabulary: shotVocabulary);
      return shot.copyWith(
        tags: r.tags,
        description: r.description,
        tagsStale: false,
        trace: TagTrace(
          sampledAtMs: at,
          framePaths: paths,
          vocabularyGroups: [for (final g in task.shotTagGroups) g.name],
          vocabularySize: shotVocabulary.length,
          rawReply: r.rawReply,
          at: clock(),
        ),
      );
    } catch (e) {
      AppLog.warn('镜头（${shot.startMs}-${shot.endMs}）视觉理解失败：$e');
      return shot;
    }
  }
}
