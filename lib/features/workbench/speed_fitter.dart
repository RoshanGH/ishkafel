import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/analysis/providers.dart' show AsrSentence;
import '../../core/export/export_commands.dart';
import '../../core/replacement/candidate_trim.dart';
import '../../core/ffmpeg/media_spec.dart';
import '../../core/ffmpeg/rendered_cache.dart';
import '../../core/log/app_log.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/playback/track_plan_builder.dart';
import '../../core/replacement/replacement_plan.dart';
import '../../core/subtitle/slot_subtitles.dart';
import '../../core/subtitle/subtitle_overlay.dart';
import '../../core/subtitle/subtitle_track.dart';
import '../../core/subtitle/subtitle_rasterizer.dart';
import '../../core/subtitle/subtitle_style.dart';

/// 把镜头替换的候选变速成「正好填满原坑位」的切片。
///
/// **这是预览里唯一还需要 ffmpeg 的一步**，因为 mpv 的 `edl://` 能描述
/// 「播哪个文件的哪一段」，但没有逐段倍速。
///
/// 只渲染**标了 ★ 的那一条**：一个镜头位可以挑好几个候选，但预览只播其中
/// 一个，其余到导出时才变速。用户原话：「只有预览的版本是需要在播，需要先
/// 变速。」——所以有镜头替换时也只渲染那么一两段，不是把整条片子切一遍。
///
/// 产物按内容指纹缓存（见 [RenderedCache]）：换候选才重渲染，换回来就是秒开。
class SpeedFitter extends ChangeNotifier {
  final RenderedCache cache;

  /// 读候选素材的真实时长——变速倍率要用它算
  final Future<int?> Function(String path) probeDurationMs;

  /// 原片的解码规格。切片必须编成同一个规格：预览是把原片与这段切片拼成
  /// 一条 EDL 播，中间换一次编码播放器就要重建解码器——用户看到的是
  /// 「突然加速、突然变慢」。为 null 表示读不出来，那就不强求
  final Future<MediaSpec?> Function()? targetSpec;

  /// 句级转写（任务的 asrSentences）。镜头替换换掉画面后，原片烧在像素里的
  /// 台词字幕跟着没了——用它在切片上重渲同一句台词。空表示没有转写
  /// （老任务/空白任务），切片照渲、不带字幕
  final List<AsrSentence> sentences;

  /// **手改过的**字幕，活取。用户在属性面板改完立刻要在预览里看到，
  /// 拷一份进来的话这个 fitter 是页面初始化时建的，永远停在打开那一刻。
  final SubtitleTrack Function()? subtitleTrackOf;

  /// 字幕样式。**活取**，理由同 [subtitleTrackOf]：顶栏「字幕」里调字号、
  /// 位置、描边，人调完立刻要在预览里看到。构造时拷一份的话，这个 fitter 是
  /// 进页面那一刻建的，永远停在默认那套——2026-09-08 真机「调整参数也没有
  /// 变化」就是这么来的（导出那条路一直用的是任务里的样式，两边对不上）。
  final SubtitleStyle Function()? subtitleStyleOf;

  /// 没给 [subtitleStyleOf] 时的兜底
  final SubtitleStyle subtitleStyle;

  SubtitleStyle get _style => subtitleStyleOf?.call() ?? subtitleStyle;

  /// 把字幕行渲成透明 PNG 的渲染器（系统渲字，见 SubtitleRasterizer）。
  /// 只有 [sentences] 非空才会用到
  final SubtitleRasterizer rasterizer;

  /// 已经渲染好的：镜头 key（见 [TrackPlanBuilder.shotKey]）→ 本地切片
  final Map<String, String> _fitted = {};

  /// 每一段是**用什么渲染出来的**（候选路径 + 坑位长度）。
  ///
  /// 有了它，[sync] 再被调用时能一眼认出「这一段已经就绪、入参也没变」，
  /// 从而**什么都不做**——既不占位也不通知。少了这一步就是个死循环：
  /// 渲完 notify → 上层重推轨道 → 又调 sync → 又走一遍占位与 notify →
  /// 再重推……界面上表现为「正在准备 1 段替换镜头」永远转下去。
  final Map<String, String> _fittedFrom = {};
  final Set<String> _running = {};
  bool _disposed = false;

  SpeedFitter({
    required this.cache,
    required this.probeDurationMs,
    this.targetSpec,
    this.sentences = const [],
    this.subtitleTrackOf,
    this.subtitleStyleOf,
    this.subtitleStyle = SubtitleStyle.standard,
    SubtitleRasterizer? rasterizer,
  }) : rasterizer = rasterizer ?? SubtitleRasterizer();

  MediaSpec? _target;
  bool _targetResolved = false;

  Future<MediaSpec?> _resolveTarget() async {
    if (_targetResolved) return _target;
    _targetResolved = true;
    try {
      _target = await targetSpec?.call();
    } catch (e) {
      AppLog.warn('读不出原片规格，变速切片按默认编码：$e');
    }
    return _target;
  }

  /// 当前可用的变速切片。还没渲染好的不在里面——上层据此把那一段先播原片，
  /// 渲染好了会 notify，再换上去
  Map<String, String> get fitted => Map.unmodifiable(_fitted);

  /// 还有几段在渲染。界面据此说「正在准备 N 段替换画面」，
  /// 而不是转一个不说话的圈
  int get pending => _running.length;

  /// 按当前方案补齐需要的切片。已经有的不重做，不再需要的从表里摘掉。
  ///
  /// [materialPathOf] 返回候选在本地的路径；还没下下来就返回 null，
  /// 那一段这次先播原片。
  Future<void> sync({
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    required String? Function(int candidateId) materialPathOf,
  }) async {
    final wanted = <String,
        ({
      int candidateId,
      int unitIndex,
      int shotIndex,
      int slotStartMs,
      int slotEndMs
    })>{};
    for (var u = 0; u < units.length && u < replacements.length; u++) {
      final replacement = replacements[u];
      if (replacement.mode != ReplacementMode.perShot) continue;
      final shots = units[u].shots;
      for (var s = 0; s < shots.length; s++) {
        final pick = replacement.shotPreviewId(s);
        if (pick == null) continue;
          wanted[TrackPlanBuilder.shotKey(u, s)] = (
          candidateId: pick,
          unitIndex: u,
          shotIndex: s,
          slotStartMs: shots[s].startMs,
          slotEndMs: shots[s].endMs,
        );
      }
    }

    // 不再需要的直接摘掉（文件留给 keepOnly 清）
    var changed = false;
    for (final key in _fitted.keys.toList()) {
      if (!wanted.containsKey(key)) {
        _fitted.remove(key);
        _fittedFrom.remove(key);
        changed = true;
      }
    }
    if (changed) _notify();

    for (final entry in wanted.entries) {
      final path = materialPathOf(entry.value.candidateId);
      if (path == null) continue; // 素材还没落到本地，这一段先播原片
      unawaited(_fit(
        key: entry.key,
        candidatePath: path,
        unitIndex: entry.value.unitIndex,
        shotIndex: entry.value.shotIndex,
        slotStartMs: entry.value.slotStartMs,
        slotEndMs: entry.value.slotEndMs,
      ));
    }
  }

  Future<void> _fit({
    required String key,
    required String candidatePath,
    required int unitIndex,
    required int shotIndex,
    required int slotStartMs,
    required int slotEndMs,
  }) async {
    // 已经就绪且入参没变：什么都不做。**这一条是死循环的闸**，见 [_fittedFrom]
    //
    // **字幕指纹必须进这道判定**：只比候选路径和坑位长度的话，用户改完字幕
    // 这里会认定「入参没变」直接返回，预览永远停在旧那一版——2026-09-08 真机
    // 的「调整字幕根本不生效」就是这么来的
    final from = _fingerprintOf(
        candidatePath: candidatePath,
        unitIndex: unitIndex,
        shotIndex: shotIndex,
        slotStartMs: slotStartMs,
        slotEndMs: slotEndMs);
    final ready = _fitted[key];
    if (_fittedFrom[key] == from &&
        ready != null &&
        File(ready).existsSync()) {
      return;
    }

    // **占位要在第一个 await 之前**：下面探时长、读规格都是异步的，
    // 把占位放在它们之后，两次调用就能同时穿过这道检查，一起去渲染同一个
    // key——先跑完的那个把 `.part` 文件改名走了，后跑完的扑空报
    // 「Cannot rename … .part.mp4」。真机日志里出现过两次
    if (_running.contains(key)) return;
    _running.add(key);
    try {
      await _fitLocked(
          key: key,
          candidatePath: candidatePath,
          unitIndex: unitIndex,
          shotIndex: shotIndex,
          slotStartMs: slotStartMs,
          slotEndMs: slotEndMs);
    } finally {
      _running.remove(key);
      _notify();
    }
  }

  /// 「这一段是用什么渲出来的」——候选、坑位、**以及要烧的那几行字**
  String _fingerprintOf({
    required String candidatePath,
    required int unitIndex,
    required int shotIndex,
    required int slotStartMs,
    required int slotEndMs,
  }) =>
      '$candidatePath|$slotStartMs-$slotEndMs|'
      '${subtitleFingerprint(_linesFor(unitIndex: unitIndex, shotIndex: shotIndex, slotStartMs: slotStartMs, slotEndMs: slotEndMs))}|'
      '${_style.fingerprint}';

  /// 这一镜要烧的字。手改过就用手改的——和导出、属性面板同一个出口
  List<SubtitleLine> _linesFor({
    required int unitIndex,
    required int shotIndex,
    required int slotStartMs,
    required int slotEndMs,
  }) =>
      subtitleLinesForSlot(
        track: subtitleTrackOf?.call() ?? const SubtitleTrack.empty(),
        sentences: sentences,
        unitIndex: unitIndex,
        shotIndex: shotIndex,
        slotStartMs: slotStartMs,
        slotEndMs: slotEndMs,
      );

  Future<void> _fitLocked({
    required String key,
    required String candidatePath,
    required int unitIndex,
    required int shotIndex,
    required int slotStartMs,
    required int slotEndMs,
  }) async {
    final slotMs = slotEndMs - slotStartMs;
    final candidateMs = await probeDurationMs(candidatePath);
    final target = await _resolveTarget();
    // 这一段坑位里要显示的台词。**内容进指纹**：改了切分、重新转写、或者人
    // 手改过这一镜的字幕之后，旧切片上烧的字就是错的，不能再命中
    final lines = _linesFor(
        unitIndex: unitIndex,
        shotIndex: shotIndex,
        slotStartMs: slotStartMs,
        slotEndMs: slotEndMs);
    final width = target?.width ?? ExportCommands.width;
    final height = target?.height ?? ExportCommands.height;
    final subFingerprint = subtitleFingerprint(lines);
    final subKey = subFingerprint.isEmpty
        ? ''
        : '|sub$subFingerprint|${_style.fingerprint}';
    // **和导出、剪映走同一个函数**：那两条路都改成「从素材里截一段」了，
    // 预览要是还整条压缩，人在软件里看到的是快进、导出来却不是——
    // 比两边都快进更糟，因为人会照着预览下判断
    final cut = trimFor(materialMs: candidateMs ?? 0, slotMs: slotMs);
    // 取段起点进指纹：换了截哪一段却复用旧切片，人看到的是「调了没反应」
    final cacheKey =
        'fit|$candidatePath|$slotMs|$candidateMs|t${cut.startMs}|$target$subKey';
    final expected =
        cache.pathFor(key: cacheKey, prefix: 'fit', extension: 'mp4');
    // 已经渲染好的直接用，一次 ffmpeg 都不跑
    if (File(expected).existsSync() && File(expected).lengthSync() > 0) {
      if (_fitted[key] != expected) {
        _fitted[key] = expected;
        _notify();
      }
      _fittedFrom[key] = _fingerprintOf(
          candidatePath: candidatePath,
          unitIndex: unitIndex,
          shotIndex: shotIndex,
          slotStartMs: slotStartMs,
          slotEndMs: slotEndMs);
      return;
    }

    _notify();
    try {
      // 字幕图放在缓存目录里、按内容指纹命名——已渲过的句子直接复用
      final overlays = lines.isEmpty
          ? const <SubtitleOverlayImage>[]
          : await rasterizer.rasterize(
              lines: lines,
              width: width,
              height: height,
              style: _style,
              outDir: cache.dir,
            );
      final out = await cache.render(
        key: cacheKey,
        prefix: 'fit',
        extension: 'mp4',
        args: (dest) => ExportCommands.fitCandidateVideo(
          input: candidatePath,
          durationMs: slotMs,
          candidateDurationMs: candidateMs,
          trimStartMs: (candidateMs ?? 0) > 0 ? cut.startMs : null,
          out: dest,
          // 和原片一个规格，播放器换段时才不用重建解码器
          target: target,
          subtitleOverlays: overlays,
        ),
        what: '把替换镜头变速对齐坑位',
      );
      _fitted[key] = out;
      _fittedFrom[key] = _fingerprintOf(
          candidatePath: candidatePath,
          unitIndex: unitIndex,
          shotIndex: shotIndex,
          slotStartMs: slotStartMs,
          slotEndMs: slotEndMs);
    } catch (e) {
      // 变速失败只影响这一段：它退回播原片，其余照旧
      AppLog.warn('镜头替换变速失败（$key）：$e');
    }
  }

  /// 把不再需要的切片从盘上清掉
  void prune() => cache.keepOnly(protect: _fitted.values.toSet());

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
