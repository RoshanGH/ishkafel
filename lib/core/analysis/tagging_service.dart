import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../ai/taggers.dart';
import '../log/app_log.dart';
import '../models/renew_task.dart';
import '../models/semantic_unit.dart';
import '../models/shot.dart';
import '../models/tag_group_ref.dart';
import '../models/tag_trace.dart';
import '../ffmpeg/thumbnail_service.dart';
import 'analysis_progress.dart';
import 'shot_frame_sampler.dart';
import 'tag_vocabulary.dart';

/// 送去视觉理解的帧高度。
///
/// 多帧时分辨率是 token 消耗的主因，而判断「画面是什么」不需要原始 1080p。
const int understandingFrameHeight = 512;

/// 两层打标：台词语义单元（文本）+ 视觉镜头（代表帧）。
///
/// 从 [AnalysisPipeline] 里拆出来，因为打标不只发生在「首次分析」这一刻：
/// 用户改完切分后可以要求重打**其中几个**单元，那时整条分析管线（抽音频、
/// ASR、语义切分）都不该再跑一遍。
class TaggingService {
  final UnitTagger? unitTagger;
  final ShotTagger? shotTagger;
  final ThumbnailService? thumbnails;

  /// 受控词表的来源。词表是**按任务**解析的（取决于该任务在新建向导里选的
  /// 标签组），所以这里注入的是「按组 id 查词表」的能力，而不是一份写死的
  /// 词表——后者等于所有任务共用一份，受控词表也就名存实亡。
  final TagVocabularySource? vocabulary;

  /// 抽代表帧的落地目录
  final Directory workDir;
  final DateTime Function() clock;

  TaggingService({
    this.unitTagger,
    this.shotTagger,
    this.thumbnails,
    this.vocabulary,
    required this.workDir,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  /// 上报一步进度。回调抛异常只记日志：进度只是「说一声」。
  void _report(AnalysisProgressSink? sink, AnalysisStage stage,
      {int? done, int? total}) {
    if (sink == null) return;
    try {
      sink(AnalysisProgress(stage: stage, done: done, total: total));
    } catch (e) {
      AppLog.warn('打标进度回调抛异常（已忽略）：$e');
    }
  }

  /// 给 [units] 打标。
  ///
  /// [only] 限定只打这几个单元（含其视觉镜头），其余原样返回——用户改完
  /// U3 要求重打时，把全片十几个单元重打一遍既慢又费钱。null 表示全打。
  Future<List<SemanticUnit>> tag(
    RenewTask task,
    List<SemanticUnit> units, {
    Set<int>? only,
    AnalysisProgressSink? onProgress,
  }) =>
      _tagUnits(task, units, onProgress, only);

  /// 取不到词表都只降级掉那一层，不中断整条分析——分析结果（切分）本身
  /// 仍然有价值，为了标签把它整条废掉不划算。
  Future<List<SemanticUnit>> _tagUnits(RenewTask task,
      List<SemanticUnit> units, AnalysisProgressSink? onProgress,
      Set<int>? only) async {
    final unitVocabulary = unitTagger == null
        ? const <String>[]
        : await _vocabularyFor(task.unitTagGroups, '台词语义单元');
    final shotVocabulary = (shotTagger == null || thumbnails == null)
        ? const <String>[]
        : await _vocabularyFor(task.shotTagGroups, '视觉镜头');

    final tagUnits = unitVocabulary.isNotEmpty;
    final tagShots = shotVocabulary.isNotEmpty;
    if (!tagUnits && !tagShots) return units;

    bool wanted(int i) => only == null || only.contains(i);

    final result = <SemanticUnit>[];
    if (tagUnits) _report(onProgress, AnalysisStage.taggingUnits, done: 0, total: units.length);
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      var updatedUnit = unit;
      if (tagUnits && wanted(i)) {
        try {
          final r = await unitTagger!.understand(
              transcript: unit.transcript, vocabulary: unitVocabulary);
          updatedUnit = updatedUnit.copyWith(
            tags: r.tags,
            tagsStale: false,
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
    return _tagAllShotsConcurrently(task, result, shotVocabulary, onProgress, only);
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
      AnalysisProgressSink? onProgress,
      Set<int>? only) async {
    final flat = <({int unit, int shot})>[
      for (var u = 0; u < units.length; u++)
        if (only == null || only.contains(u))
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
    // byUnit 只包含被打过的单元；没打的单元下面走 `?? units[u].shots` 原样保留
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
