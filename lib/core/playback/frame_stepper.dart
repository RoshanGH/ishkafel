import '../editing/frame_time.dart';

/// 逐帧步进的定位计算。
///
/// 两个坑，缺一不可地导致「按住方向键走着走着卡住不动」：
///
/// 1. **在毫秒上加常数**。30fps 下帧点是 0、33、67、100、133、167…
///    （间距 33/34 交替），按 `+round(1000/30)=+33` 走：33+33=66，而 66ms
///    仍落在第 1 帧的显示区间 [33,67) 内——画面纹丝不动。每走三四步就必然
///    重复一次。必须回到帧序号域加减。
///
/// 2. **每次都从播放器上报的位置反推帧号**。按住不放时步进连发，而 seek 是
///    异步的，播放器位置还停在上一次的值，反推出来还是旧帧号，于是原地踏步。
///    因此连续步进期间自己记住锚点帧，不再问播放器。
class FrameStepper {
  /// 连续步进期间的锚点帧；null 表示下一次要以播放器当前位置为准
  int? _anchor;

  /// 算出步进 [frames] 帧后应当定位到的毫秒。
  ///
  /// [positionMs] 只在**开始一段新的连续步进**时用到（锚点为空时）。
  int nextMs({
    required int positionMs,
    required int frames,
    required double fps,
    required int durationMs,
  }) {
    if (!fps.isFinite || fps <= 0) return positionMs;
    final lastFrame = _lastFrameOf(durationMs, fps);
    final base = _anchor ?? frameIndex(positionMs, fps);
    final target = (base + frames).clamp(0, lastFrame);
    _anchor = target;
    return msOfFrame(target, fps);
  }

  /// 片子的最后一帧：定位到片长本身会落到片尾之外
  static int _lastFrameOf(int durationMs, double fps) {
    if (durationMs <= 0) return 0;
    final span = FrameSpan.fromMs(0, durationMs, fps);
    return span.last;
  }

  /// 放弃锚点。任何**不是逐帧步进**的定位（点刻度尺、拖播放头、双击播放
  /// 片段、正常播放）之后都要调用它，否则下一次步进会从早已过期的锚点跳走。
  void reset() => _anchor = null;
}
