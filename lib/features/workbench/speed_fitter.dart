import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/export/export_commands.dart';
import '../../core/replacement/candidate_trim.dart';
import '../../core/ffmpeg/media_spec.dart';
import '../../core/ffmpeg/rendered_cache.dart';
import '../../core/log/app_log.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/playback/track_plan_builder.dart';
import '../../core/replacement/replacement_plan.dart';

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
///
/// **切片上不带字幕。** 字幕曾经烧在这里，于是调一次字号、挪一次位置就要
/// 重渲一遍、换一次播放源——转圈几秒、播放头弹回片头（2026-09-09 用户原话：
/// 「每次都要有一个加载的动效，然后跳转到第一帧，这个跳转太煞笔了」）。
/// 现在预览的字幕由画面上现画的一层负责（见 [PreviewSubtitleLayer] 与
/// `core/subtitle/preview_subtitle_at.dart`），这里只管把画面变速铺满坑位；
/// 导出仍旧照 spec 烧录（见 `export_runner`）。
class SpeedFitter extends ChangeNotifier {
  final RenderedCache cache;

  /// 读候选素材的真实时长——变速倍率要用它算
  final Future<int?> Function(String path) probeDurationMs;

  /// 原片的解码规格。切片必须编成同一个规格：预览是把原片与这段切片拼成
  /// 一条 EDL 播，中间换一次编码播放器就要重建解码器——用户看到的是
  /// 「突然加速、突然变慢」。为 null 表示读不出来，那就不强求
  final Future<MediaSpec?> Function()? targetSpec;

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
  });

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
      int slotEndMs,
      int? trimStartMs
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
          // 人/Agent 调过的起点也要带上：预览不认它的话，软件里看到的
          // 是从头开始的那一段、导出来却是跳过开头的——「我看到的和导出来
          // 的不一样」正是这条线最难查的错
          trimStartMs:
              replacement.trimStartOf(shotIndex: s, candidateId: pick),
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
        trimStartMs: entry.value.trimStartMs,
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
    int? trimStartMs,
  }) async {
    // 已经就绪且入参没变：什么都不做。**这一条是死循环的闸**，见 [_fittedFrom]
    //
    // **字幕指纹必须进这道判定**：只比候选路径和坑位长度的话，用户改完字幕
    // 这里会认定「入参没变」直接返回，预览永远停在旧那一版——2026-09-08 真机
    // 的「调整字幕根本不生效」就是这么来的
    final from = _fingerprintOf(
        candidatePath: candidatePath,
        slotStartMs: slotStartMs,
        slotEndMs: slotEndMs,
        trimStartMs: trimStartMs);
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
          slotEndMs: slotEndMs,
          trimStartMs: trimStartMs);
    } finally {
      _running.remove(key);
      _notify();
    }
  }

  /// 「这一段是用什么渲出来的」——候选、坑位、取段起点。
  ///
  /// **字幕不在里面**：切片上不带字（见类注释），所以改字号、挪位置、
  /// 改台词都不该让这里失效重渲
  String _fingerprintOf({
    required String candidatePath,
    required int slotStartMs,
    required int slotEndMs,
    int? trimStartMs,
  }) =>
      '$candidatePath|$slotStartMs-$slotEndMs|t${trimStartMs ?? 0}';

  Future<void> _fitLocked({
    required String key,
    required String candidatePath,
    required int unitIndex,
    required int shotIndex,
    required int slotStartMs,
    required int slotEndMs,
    int? trimStartMs,
  }) async {
    final slotMs = slotEndMs - slotStartMs;
    final candidateMs = await probeDurationMs(candidatePath);
    final target = await _resolveTarget();
    // **和导出、剪映走同一个函数**：三条路必须给出同一个答案，
    // 否则人会照着预览下判断、拿到一条不一样的成片
    final cut = trimFor(
        materialMs: candidateMs ?? 0, slotMs: slotMs, startMs: trimStartMs);
    // 取段起点进指纹：换了截哪一段却复用旧切片，人看到的是「调了没反应」。
    // **v3 起切片上不带字幕**：v2 的缓存里烧着字，复用它画面上就是两层字
    final cacheKey =
        'fit|v3|$candidatePath|$slotMs|$candidateMs|t${cut.startMs}|$target';
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
          slotStartMs: slotStartMs,
          slotEndMs: slotEndMs,
          trimStartMs: trimStartMs);
      return;
    }

    _notify();
    try {
      final out = await cache.render(
        key: cacheKey,
        prefix: 'fit',
        extension: 'mp4',
        args: (dest) => ExportCommands.fitCandidateVideo(
          input: candidatePath,
          durationMs: slotMs,
          candidateDurationMs: candidateMs,
          trimStartMs:
              (candidateMs ?? 0) > 0 && cut.startMs > 0 ? cut.startMs : null,
          out: dest,
          // 和原片一个规格，播放器换段时才不用重建解码器
          target: target,
        ),
        what: '把替换镜头变速对齐坑位',
      );
      _fitted[key] = out;
      _fittedFrom[key] = _fingerprintOf(
          candidatePath: candidatePath,
          slotStartMs: slotStartMs,
          slotEndMs: slotEndMs,
          trimStartMs: trimStartMs);
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
