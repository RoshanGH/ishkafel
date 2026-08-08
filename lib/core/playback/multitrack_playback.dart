import 'dart:async';

import 'package:flutter/widgets.dart';

import '../log/app_log.dart';
import 'edl.dart';
import 'follower_track.dart';
import 'media_kit_playback.dart';
import 'playback_controller.dart';
import 'track_plan.dart';

/// 三条独立轨同时播：画面 + 口播 + 配乐。
///
/// **为什么不再预合成**：此前预览要先用 ffmpeg 把几十段拼成一整条新片子再喂
/// 给播放器，一轮几分钟、几百兆磁盘，而其中绝大多数段是把原片原封不动切了
/// 一遍。用户原话：「它就不能像剪映一样各是各的吗？播放的时候一起播放。」
///
/// 分工：
/// - **画面轨**是主时钟，且**静音**——它播的可能是候选素材，那条素材自带的
///   声音由口播轨负责取（整体替换要它、镜头替换要丢掉它），画面轨出声只会
///   变成两份声音重叠；
/// - **口播轨**跟着主时钟走，偏差超过 [syncToleranceMs] 才纠一次；
/// - **配乐轨**按范围启停：进入某一段就 seek 到曲子对应的位置播，出了范围
///   就停（「太长就播到段尾停」），曲子比段短就绕回开头（「不够长就循环」）。
///
/// 画面轨复用 [MediaKitPlaybackController]——那里面沉淀了一串 mpv 的坑
/// （eof 后 play 会从头播、清 end 会自己恢复播放、销毁竞态会让进程 abort），
/// 不该为了多轨再踩一遍。
class MultitrackPlayback implements PlaybackController {
  /// 画面轨兼主时钟
  final MediaKitPlaybackController video;
  final FollowerTrack voice;
  final FollowerTrack bgm;

  /// 多久校一次跟随轨。太密会被采样抖动骗得反复 seek，太疏则接缝期变长
  final Duration syncInterval;

  TrackPlan _plan = TrackPlan.empty;
  StreamSubscription<int>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _syncTimer;
  BgmCue _bgmCue = BgmCue.silent;
  bool _disposed = false;

  MultitrackPlayback({
    required this.video,
    required this.voice,
    required this.bgm,
    this.syncInterval = const Duration(milliseconds: 500),
  }) {
    _positionSub = video.positionMsStream.listen(_onMasterPosition);
    _playingSub = video.playingStream.listen(_onMasterPlaying);
  }

  TrackPlan get plan => _plan;

  /// 换一套轨。**位置保持不变**——用户改了个候选就被弹回片头是不能接受的。
  ///
  /// 画面轨为空（一处替换都没有、且没拿到原片）时什么都不做。
  Future<void> setPlan(TrackPlan plan) async {
    _plan = plan;
    final at = video.positionMs;

    final videoEdl = Edl.of(plan.video);
    if (videoEdl != null) await video.open(videoEdl);
    await voice.load(Edl.of(plan.voice));

    // 换源之后位置回到 0，把它拉回用户原来看的地方
    if (at > 0 && at < plan.totalMs) {
      await video.seekMs(at);
      await voice.seekMs(at);
    }
    await _applyBgm(video.positionMs, force: true);
  }

  void _onMasterPosition(int masterMs) {
    if (_disposed) return;
    unawaited(_applyBgm(masterMs));
  }

  void _onMasterPlaying(bool playing) {
    if (_disposed) return;
    unawaited(_syncPlaying(playing));
    if (playing) {
      _syncTimer ??= Timer.periodic(syncInterval, (_) => _correctDrift());
    } else {
      _syncTimer?.cancel();
      _syncTimer = null;
    }
  }

  Future<void> _syncPlaying(bool playing) async {
    if (playing) {
      await voice.play();
      if (_bgmCue.source != null) await bgm.play();
    } else {
      await voice.pause();
      await bgm.pause();
    }
  }

  /// 跟随轨漂了就拉回来。只在偏差超过容许值时动手——每次 seek 都是一次
  /// 可闻的接缝，被采样抖动骗着反复 seek 比漂几十毫秒难受得多。
  Future<void> _correctDrift() async {
    if (_disposed) return;
    final masterMs = video.positionMs;
    if (needsResync(masterMs: masterMs, followerMs: voice.positionMs)) {
      AppLog.info('口播轨偏了 ${voice.positionMs - masterMs}ms，纠回来');
      await voice.seekMs(masterMs);
    }
    final cue = _bgmCue;
    if (cue.source == null) return;
    final want = _plan.bgmAt(masterMs)?.sourceMsAt(masterMs);
    if (want != null &&
        needsResync(masterMs: want, followerMs: bgm.positionMs)) {
      await bgm.seekMs(want);
    }
  }

  /// 配乐按范围启停。只在**换段/换曲/换音量**时下命令——每帧都 seek 会把
  /// 曲子搅成噪音。
  Future<void> _applyBgm(int masterMs, {bool force = false}) async {
    final cue = bgmCueAt(_plan, masterMs);
    final changedSource = cue.source != _bgmCue.source;
    final changedVolume = cue.volume != _bgmCue.volume;
    if (!force && !changedSource && !changedVolume) return;
    _bgmCue = cue;

    if (cue.source == null) {
      await bgm.pause();
      return;
    }
    if (changedSource || force) {
      await bgm.load(cue.source);
      await bgm.seekMs(cue.inMs);
    }
    await bgm.setVolume(cue.volume);
    if (video.isPlaying) await bgm.play();
  }

  // ——— 以下把控制转发给主时钟，跟随轨随后对齐 ———

  @override
  Future<void> open(String path) => video.open(path);

  @override
  Future<void> play() async {
    await video.play();
    // playingStream 也会触发一次，这里显式来一遍避免首帧那一刻的空档
    await _syncPlaying(true);
  }

  @override
  Future<void> pause() async {
    await video.pause();
    await _syncPlaying(false);
  }

  @override
  Future<void> seekMs(int ms) async {
    await video.seekMs(ms);
    await voice.seekMs(ms);
    await _applyBgm(ms, force: true);
  }

  @override
  Future<bool> playRange(int startMs, int endMs, double fps) async {
    final ok = await video.playRange(startMs, endMs, fps);
    if (!ok) return false;
    await voice.seekMs(startMs);
    await _applyBgm(startMs, force: true);
    await _syncPlaying(true);
    return true;
  }

  @override
  Future<void> clearRange() => video.clearRange();

  @override
  Future<void> stepFrames(int frames, double fps) async {
    await video.stepFrames(frames, fps);
    // 逐帧看画面时不必让声音跟着一帧一帧跳，但位置要对上，
    // 下次按播放才不会从错的地方接上
    await voice.seekMs(video.positionMs);
    await _applyBgm(video.positionMs, force: true);
  }

  @override
  Stream<int> get positionMsStream => video.positionMsStream;

  @override
  Stream<bool> get playingStream => video.playingStream;

  @override
  int get positionMs => video.positionMs;

  @override
  bool get isPlaying => video.isPlaying;

  /// 多轨模式下没有「外挂音轨」这回事——声音本来就在独立的轨上。
  /// 返回 false 让调用方知道不必走那条老路。
  @override
  Future<bool> setExternalAudio(String path) async => false;

  @override
  Future<void> clearExternalAudio() async {}

  @override
  Future<void> dispose() async {
    _disposed = true;
    _syncTimer?.cancel();
    await _positionSub?.cancel();
    await _playingSub?.cancel();
    await voice.dispose();
    await bgm.dispose();
    await video.dispose();
  }

  Widget buildVideoWidget() => video.buildVideoWidget();
}
