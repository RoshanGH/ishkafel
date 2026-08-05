import 'dart:io';

import 'package:path/path.dart' as p;

import '../ai/tag_dimension.dart';
import '../ai/taggers.dart';
import '../log/app_log.dart';
import '../models/renew_task.dart';
import '../models/semantic_unit.dart';
import '../models/shot.dart';
import '../models/tag_group_ref.dart';
import '../models/tag_trace.dart';
import '../ffmpeg/thumbnail_service.dart';
import 'analysis_progress.dart';
import 'local_work_gate.dart';
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
        ? const <TagDimension>[]
        : await _dimensionsFor(task.unitTagGroups, '台词语义单元');
    final shotVocabulary = (shotTagger == null || thumbnails == null)
        ? const <TagDimension>[]
        : await _dimensionsFor(task.shotTagGroups, '视觉镜头');

    final tagUnits = unitVocabulary.isNotEmpty;
    final tagShots = shotVocabulary.isNotEmpty;
    if (!tagUnits && !tagShots) return units;

    bool wanted(int i) => only == null || only.contains(i);

    // 单元打标全并发。此前是一个一个跑：7 个单元 143 秒，每个 20 秒都在等
    // 网络往返——而云端并发是免费的
    final result = List<SemanticUnit>.of(units);
    if (tagUnits) {
      _report(onProgress, AnalysisStage.taggingUnits, done: 0, total: units.length);
      var done = 0;
      await Future.wait([
        for (var i = 0; i < units.length; i++)
          if (wanted(i))
            () async {
              final unit = units[i];
              try {
                final r = await unitTagger!.understand(
                  transcript: unit.transcript,
                  dimensions: unitVocabulary,
                  constraint: task.unitTagPrompt,
                );
                result[i] = unit.copyWith(
                  tags: r.tags,
                  tagsStale: false,
                  trace: _traceOf(r, unitVocabulary,
                      constraint: task.unitTagPrompt,
                      textInput: unit.transcript),
                );
              } catch (e) {
                AppLog.warn('单元 ${unit.index} 打标失败：$e');
              }
              _report(onProgress, AnalysisStage.taggingUnits,
                  done: ++done, total: units.length);
            }(),
      ]);
    }
    if (!tagShots) return result;
    return _tagAllShotsConcurrently(task, result, shotVocabulary, onProgress, only);
  }

  /// 云端调用**不限并发**。
  ///
  /// 实测本账号并发 24 的视觉调用零限流，而且并发越高单次均摊越低
  /// （并发 4 时 4.7s/次，并发 24 时 1.1s/次）——之前那个「并发 4」的上限
  /// 是凭空设的，白白把 58 个镜头的打标拖成 5 分半。
  ///
  /// 本地那一头仍然要拦（见 [LocalWorkGate]）：58 个镜头各抽 3 帧，
  /// 一次性放出 174 个 ffmpeg 进程抢 8 个核，只会互相拖慢。

  /// 给全片的视觉镜头并发打标。
  ///
  /// 并发要跨单元而不是只在单元内部：真实素材里很多单元只包含一个镜头，
  /// 按单元并发等于没并发。结果按全局下标回填——按完成顺序收集会把标签
  /// 串到别的镜头上。
  Future<List<SemanticUnit>> _tagAllShotsConcurrently(
      RenewTask task,
      List<SemanticUnit> units,
      List<TagDimension> vocabulary,
      AnalysisProgressSink? onProgress,
      Set<int>? only) async {
    final flat = <({int unit, int shot})>[
      for (var u = 0; u < units.length; u++)
        if (only == null || only.contains(u))
          for (var s = 0; s < units[u].shots.length; s++) (unit: u, shot: s),
    ];
    if (flat.isEmpty) return units;

    final tagged = List<Shot?>.filled(flat.length, null);
    // 完成计数与回填下标是两回事：并发下第 5 个开工的可能第 1 个结束，
    // 用下标当进度会让数字来回跳
    var completed = 0;
    _report(onProgress, AnalysisStage.taggingShots, done: 0, total: flat.length);

    await Future.wait([
      for (var i = 0; i < flat.length; i++)
        () async {
          final at = flat[i];
          tagged[i] = await _tagShot(
              task, units[at.unit].shots[at.shot], i, vocabulary);
          _report(onProgress, AnalysisStage.taggingShots,
              done: ++completed, total: flat.length);
        }(),
    ]);

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
  Future<List<TagDimension>> _dimensionsFor(
      List<TagGroupRef> groups, String layer) async {
    final source = vocabulary;
    if (groups.isEmpty || source == null) return const [];
    final dimensions = <TagDimension>[];
    for (final group in groups) {
      try {
        final words = await source.vocabularyOf(group.id);
        if (words.isEmpty) {
          AppLog.warn('$layer 标签组「${group.name}」内没有任何标签');
          continue;
        }
        dimensions.add(TagDimension(name: group.name, vocabulary: words));
      } catch (e) {
        AppLog.warn('$layer 标签组「${group.name}」的词表拉取失败，跳过这个组：$e');
      }
    }
    if (dimensions.isEmpty) {
      AppLog.warn('$layer 没有可用的受控词表，跳过该层打标');
    }
    return List.unmodifiable(dimensions);
  }

  /// 把这次调用的过程量记下来。
  ///
  /// 维度、词表大小、以及用户为这一层写的约束都要留痕——标签不对时，
  /// 「喂进去的约束是什么」往往才是问题所在。
  TagTrace _traceOf(
    ShotUnderstanding r,
    List<TagDimension> dimensions, {
    String? constraint,
    String? textInput,
    List<int> sampledAtMs = const [],
    List<String> framePaths = const [],
  }) =>
      TagTrace(
        textInput: textInput,
        sampledAtMs: sampledAtMs,
        framePaths: framePaths,
        vocabularyGroups: [for (final d in dimensions) d.name],
        vocabularySize:
            dimensions.fold<int>(0, (n, d) => n + d.vocabulary.length),
        prompt: constraint?.trim().isNotEmpty == true ? constraint : null,
        tagsByDimension: r.tagsByDimension,
        rawReply: r.rawReply,
        at: clock(),
      );

  /// 视觉理解一个镜头：按秒采样多帧 → 一次调用同时拿标签与画面描述。
  ///
  /// 缩到 512 宽再送：多帧时分辨率是 token 消耗的主因，而判断「画面是什么」
  /// 不需要原始 1080p。
  Future<Shot> _tagShot(RenewTask task, Shot shot, int shotIndex,
      List<TagDimension> shotVocabulary) async {
    try {
      final at = ShotFrameSampler.sampleAt(
          startMs: shot.startMs, endMs: shot.endMs);
      final frames = <List<int>>[];
      final paths = <String>[];
      for (var i = 0; i < at.length; i++) {
        final outPath =
            p.join(workDir.path, '${task.id}_shot${shotIndex}_$i.jpg');
        paths.add(outPath);
        await LocalWorkGate.shared.run(() => thumbnails!.extractCover(
              videoPath: task.sourcePath,
              outPath: outPath,
              atSeconds: at[i] / 1000.0,
              height: understandingFrameHeight,
            ));
        frames.add(await File(outPath).readAsBytes());
      }
      final r = await shotTagger!.understand(
        frames: frames,
        dimensions: shotVocabulary,
        constraint: task.shotTagPrompt,
      );
      return shot.copyWith(
        tags: r.tags,
        description: r.description,
        tagsStale: false,
        trace: _traceOf(r, shotVocabulary,
            constraint: task.shotTagPrompt,
            sampledAtMs: at,
            framePaths: paths),
      );
    } catch (e) {
      AppLog.warn('镜头（${shot.startMs}-${shot.endMs}）视觉理解失败：$e');
      return shot;
    }
  }
}
