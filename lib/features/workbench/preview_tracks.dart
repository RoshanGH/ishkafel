import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/audio/bgm_plan.dart';
import '../../core/audio/voice_plan.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/playback/multitrack_playback.dart';
import '../../core/playback/track_plan.dart';
import '../../core/playback/track_plan_builder.dart';
import '../../core/replacement/replacement_plan.dart';
import '../picking/picked_media_cache.dart';
import 'speed_fitter.dart';

/// 把「替换方案」推成「三条轨」，并交给多轨播放器。
///
/// 取代了原来那套「ffmpeg 预合成 + 外挂音轨」：现在换个候选、换首配乐、拉个
/// 音量都是**改一个字符串再让播放器换源**，不生成任何中间文件。唯一还要等的
/// 是镜头替换的变速切片（见 [SpeedFitter]），而它只渲染标了 ★ 的那一条。
class PreviewTracks extends ChangeNotifier {
  final MultitrackPlayback playback;

  /// 已选素材的本地固定（画面）与配乐的本地固定。取不到路径的那一段
  /// 当没选——预览宁可播原片，也不能播一个空洞
  final PickedMediaCache? materials;
  final PickedMediaCache? bgmMedia;
  final SpeedFitter? speedFitter;

  TrackPlan _plan = TrackPlan.empty;
  String? _lastKey;
  bool _disposed = false;

  PreviewTracks({
    required this.playback,
    this.materials,
    this.bgmMedia,
    this.speedFitter,
  }) {
    speedFitter?.addListener(_onFitterChanged);
  }

  TrackPlan get plan => _plan;

  /// 这一刻要不要告诉用户「还在准备」。为 null 表示一切就绪，不该有横幅——
  /// 多轨播放本来就不需要等合成，只有变速切片会花几秒
  String? get notice {
    final pending = speedFitter?.pending ?? 0;
    if (pending > 0) {
      return '正在准备 $pending 段替换镜头的变速画面，其余部分已经能播';
    }
    if (_plan.bgmMissing.isNotEmpty) return _plan.bgmMissing.join('；');
    return null;
  }

  /// 成片时刻 → 原片时刻。时间线画的是原片切分，播放头要靠它换算回去
  int toSourceMs(int composedMs) {
    for (final segment in _plan.video) {
      if (!segment.covers(composedMs)) continue;
      // 整体替换那一段没有对应的原片时刻，就近落在这一段的起点
      return segment.sourceMsAt(composedMs);
    }
    return composedMs;
  }

  /// 方案有任何变化时调用。与画面/声音无关的改动会被指纹挡掉。
  /// 原片的预览代理。null 表示还没生成好，这一轮先播原片
  String? proxyPath;

  Future<void> update({
    required RenewTask task,
    required List<SemanticUnit> units,
    required Map<int, String> voiceAudio,
    List<UnitReplacement> replacements = const [],
  }) async {
    // 变速切片要按新方案补齐；补好了会回调，那时再重建一次
    unawaited(speedFitter?.sync(
      units: units,
      replacements: replacements,
      materialPathOf: (id) => materials?.localPathOf(id),
    ));

    final plan = _build(
      task: task,
      units: units,
      voiceAudio: voiceAudio,
      replacements: replacements,
    );
    final key = _keyOf(plan);
    if (key == _lastKey) return;
    _lastKey = key;
    _plan = plan;
    await playback.setPlan(plan);
    _notify();
  }

  TrackPlan _build({
    required RenewTask task,
    required List<SemanticUnit> units,
    required Map<int, String> voiceAudio,
    required List<UnitReplacement> replacements,
  }) {
    // 时长取自落地记录（挑素材时探过一次，随任务存着），不必再 ffprobe
    final durations = {
      for (final m in task.pickedMaterials)
        if (m.durationMs != null) m.id: m.durationMs!,
    };
    final local = <int, LocalMaterial>{};
    for (final m in task.pickedMaterials) {
      final path = materials?.localPathOf(m.id);
      if (path == null) continue;
      local[m.id] = LocalMaterial(path: path, durationMs: durations[m.id]);
    }
    final bgmPaths = <int, String>{
      for (final material in task.bgm.materials)
        material.id: ?bgmMedia?.localPathOf(material.id),
    };

    return TrackPlanBuilder.build(
      // 画面走代理（规格统一，接缝处不必重建解码器）；代理还没生成好就先播
      // 原片。声音那一路始终读原片——音频解码不吃硬件，没理由多绕一层
      sourcePath: proxyPath ?? task.sourcePath,
      audioSourcePath: task.sourcePath,
      units: units,
      replacements: replacements,
      materials: local,
      speedFitted: speedFitter?.fitted ?? const {},
      vocalsPath: task.vocalsPath,
      voiceAudio: voiceAudio,
      bgm: task.bgm,
      bgmPaths: bgmPaths,
    );
  }

  /// 轨道方案的指纹。相同就不换源——换源会让播放器重新打开文件，
  /// 有一次可见的闪
  static String _keyOf(TrackPlan plan) => [
        for (final s in plan.video) '${s.atMs}:${s.durationMs}:${s.source}:${s.inMs}',
        '|',
        for (final s in plan.voice) '${s.atMs}:${s.durationMs}:${s.source}:${s.inMs}',
        '|',
        for (final s in plan.bgm)
          '${s.clip.atMs}:${s.clip.durationMs}:${s.clip.source}:${s.volume}',
      ].join(',');

  void _onFitterChanged() {
    _notify();
    // 变速切片好了：让上层带着最新方案再推一次
    onNeedsRebuild?.call();
  }

  /// 变速切片就绪时回调，让上层用最新方案重建一次轨道
  VoidCallback? onNeedsRebuild;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    speedFitter?.removeListener(_onFitterChanged);
    super.dispose();
  }
}

/// 有配乐或配音、但没有分离出来的人声轨时的提醒。
///
/// 这种情况下新配乐只能叠在原声上，原片自带的背景音还在——两首曲子一起响。
/// 用户听到的东西不对，必须说清是为什么。
String? missingVocalsNotice(BgmPlan bgm, VoicePlan voices, String? vocalsPath) {
  if (bgm.segments.isEmpty) return null;
  if (vocalsPath != null && File(vocalsPath).existsSync()) return null;
  return '没有分离出纯人声轨，新配乐会与原片自带的背景音叠在一起。'
      '装好人声分离工具后重新分析可解决';
}
