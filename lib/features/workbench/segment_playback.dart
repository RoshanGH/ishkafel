import 'dart:async';

import '../../core/log/app_log.dart';
import '../../core/playback/playback_controller.dart';

/// 「只播这一段」：从片段起点一帧一帧正常播到**本段最后一帧**，然后停住。
///
/// 双击时间线上的台词语义单元 / 视觉镜头就走这里——逐段试看是审片的主要
/// 动作，比「从这里一直播下去」有用得多。
///
/// **停的动作交给播放器自己做**（[PlaybackController.playRange]）。曾经的
/// 做法是在这里盯位置流、发现越过终点就暂停再 seek 回去——那是错的：位置
/// 回调是离散采样的，触发时往往已经过头几十毫秒，拉回来在画面上就是一次
/// 肉眼可见的回跳。用户要的是正常播到最后一帧停下，不是播过了再倒带。
///
/// 相邻片段是无缝覆盖的半开区间（S1 = [0, 2000)、S2 = [2000, 5000)），
/// 终点 `endMs` 属于**下一段**，所以传给播放器的终点就是 endMs 本身：
/// 播到它之前的最后一帧为止，正好是本段的最后一帧。
class SegmentPlayback {
  final PlaybackController playback;

  StreamSubscription<bool>? _playingWatch;
  bool _active = false;

  SegmentPlayback(this.playback);

  /// 当前是否正处于「只播这一段」状态
  bool get isActive => _active;

  /// 播放 [startMs, endMs)。区间非法（终点不在起点之后）时不发任何指令——
  /// 零长度片段播了也只能立刻停，白闪一下不如不动。
  Future<void> play(int startMs, int endMs, double fps) async {
    await cancel();
    if (endMs <= startMs) return;

    final ranged = await playback.playRange(startMs, endMs, fps);
    if (!ranged) {
      // 没有区间能力（播放器降级成无播放模式）时不假装停得住：
      // 老老实实从起点播，不去做那套会回跳的轮询兜底
      AppLog.info('播放器不支持区间播放，双击片段退化为从起点播放');
      await playback.seekMs(startMs);
      await playback.play();
      return;
    }
    _active = true;
    // 播到段尾时**不去解除区间**：mpv 是以「EOF + keep-open」的形态停住的，
    // 这时清掉终点它会自己恢复播放（实测停在 2.6s 后二十秒跑到了 21s）。
    // 就让它停在那儿；真正要继续播时（PlaybackController.play）再解除。
    _playingWatch = playback.playingStream.listen((playing) {
      if (!playing) _stopWatching();
    });
  }

  /// 只撤监听、不碰播放器（段尾自然停住时用）
  void _stopWatching() {
    _playingWatch?.cancel();
    _playingWatch = null;
    _active = false;
  }

  /// 解除区间限制。用户自己拖了播放头、点了刻度尺都该调用它——
  /// 否则播到某个位置会莫名其妙地停下。
  Future<void> cancel() async {
    final wasActive = _active;
    _stopWatching();
    if (!wasActive) return;
    try {
      await playback.clearRange();
    } catch (e) {
      AppLog.warn('解除片段播放区间失败：$e');
    }
  }

  void dispose() {
    _playingWatch?.cancel();
    _playingWatch = null;
    _active = false;
  }
}
