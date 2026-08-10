import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/export/export_commands.dart';
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
    final wanted = <String, ({int candidateId, int slotMs})>{};
    for (var u = 0; u < units.length && u < replacements.length; u++) {
      final replacement = replacements[u];
      if (replacement.mode != ReplacementMode.perShot) continue;
      final shots = units[u].shots;
      for (var s = 0; s < shots.length; s++) {
        final pick = replacement.shotPreviewId(s);
        if (pick == null) continue;
        wanted[TrackPlanBuilder.shotKey(u, s)] = (
          candidateId: pick,
          slotMs: shots[s].endMs - shots[s].startMs,
        );
      }
    }

    // 不再需要的直接摘掉（文件留给 keepOnly 清）
    var changed = false;
    for (final key in _fitted.keys.toList()) {
      if (!wanted.containsKey(key)) {
        _fitted.remove(key);
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
        slotMs: entry.value.slotMs,
      ));
    }
  }

  Future<void> _fit({
    required String key,
    required String candidatePath,
    required int slotMs,
  }) async {
    // **占位要在第一个 await 之前**：下面探时长、读规格都是异步的，
    // 把占位放在它们之后，两次调用就能同时穿过这道检查，一起去渲染同一个
    // key——先跑完的那个把 `.part` 文件改名走了，后跑完的扑空报
    // 「Cannot rename … .part.mp4」。真机日志里出现过两次
    if (_running.contains(key)) return;
    _running.add(key);
    try {
      await _fitLocked(key: key, candidatePath: candidatePath, slotMs: slotMs);
    } finally {
      _running.remove(key);
      _notify();
    }
  }

  Future<void> _fitLocked({
    required String key,
    required String candidatePath,
    required int slotMs,
  }) async {
    final candidateMs = await probeDurationMs(candidatePath);
    final target = await _resolveTarget();
    final cacheKey = 'fit|$candidatePath|$slotMs|$candidateMs|$target';
    final expected =
        cache.pathFor(key: cacheKey, prefix: 'fit', extension: 'mp4');
    // 已经渲染好的直接用，一次 ffmpeg 都不跑
    if (File(expected).existsSync() && File(expected).lengthSync() > 0) {
      if (_fitted[key] != expected) {
        _fitted[key] = expected;
        _notify();
      }
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
          out: dest,
          // 和原片一个规格，播放器换段时才不用重建解码器
          target: target,
        ),
        what: '把替换镜头变速对齐坑位',
      );
      _fitted[key] = out;
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
