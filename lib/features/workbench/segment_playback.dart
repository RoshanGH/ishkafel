import 'dart:async';

import '../../core/editing/frame_time.dart';
import '../../core/log/app_log.dart';
import '../../core/playback/playback_controller.dart';

/// 「只播这一段」：从片段起点播到终点自动停。
///
/// 双击时间线上的台词语义单元 / 视觉镜头就走这里——逐段试看是审片的主要
/// 动作，比「从这里一直播下去」有用得多。
///
/// 播放器本身没有区间播放能力，这里靠盯位置流实现。两个坑必须防住：
/// - **seek 尚未生效前的旧位置**：`seekMs` 之后播放器还会报几次上一次的位置。
///   若那个位置正好在终点之后，片段刚播就被掐停。因此先要观察到一个「确实
///   落在区间内」的位置，之后的判定才作数。
/// - **监听不撤**：停过之后不撤订阅，用户手动再播时会被反复摁停。
///
/// 停在哪一帧也讲究：相邻片段是无缝覆盖的半开区间（S1 = [0, 2000)、
/// S2 = [2000, 5000)），终点 `endMs` **就是下一段的第一帧**。停在那里等于
/// 双击 S1 却看到 S2 的画面。因此停的目标是 [lastFrameBefore]，而且暂停后
/// 要显式定位回去——位置回调是离散采样的，触发时往往已经越过终点几十毫秒。
class SegmentPlayback {
  final PlaybackController playback;

  StreamSubscription<int>? _watch;

  /// 停的目标：这一段的**最后一帧**（不是终点，终点属于下一段）
  int? _stopAtMs;

  /// 是否已经观察到「位置确实进到区间内」（防住 seek 前的残留位置）
  bool _armed = false;

  SegmentPlayback(this.playback);

  /// 播放 [startMs, endMs)，走到这一段的最后一帧即停。区间非法（终点不在
  /// 起点之后）时不发任何指令——零长度片段播了也只能立刻停，白闪一下不如不动。
  Future<void> play(int startMs, int endMs, double fps) async {
    cancel();
    if (endMs <= startMs) return;

    // 至少不早于起点：一帧长的片段里 lastFrameBefore 可能落在起点之前
    final stopAt = lastFrameBefore(endMs, fps);
    _stopAtMs = stopAt < startMs ? startMs : stopAt;
    _armed = false;
    _watch = playback.positionMsStream.listen(_onPosition);
    await playback.seekMs(startMs);
    await playback.play();
  }

  void _onPosition(int ms) {
    final stopAt = _stopAtMs;
    if (stopAt == null) return;
    if (!_armed) {
      // 还没看到区间内的位置，说明 seek 还没落地，这一拍不作数
      if (ms <= stopAt) _armed = true;
      return;
    }
    if (ms < stopAt) return;
    cancel();
    unawaited(_stopOn(stopAt));
  }

  /// 先停再定位：顺序反过来的话，定位完成前播放还在往前走，刚拉回来又跑掉
  Future<void> _stopOn(int ms) async {
    try {
      await playback.pause();
      await playback.seekMs(ms);
    } catch (e) {
      AppLog.warn('片段播放收尾失败（暂停/定位）：$e');
    }
  }

  /// 放弃当前片段约束。用户自己拖了播放头、按了空格、点了别处都该调用它——
  /// 否则播到某个位置会莫名其妙地停下。
  void cancel() {
    _watch?.cancel();
    _watch = null;
    _stopAtMs = null;
    _armed = false;
  }

  void dispose() => cancel();
}
