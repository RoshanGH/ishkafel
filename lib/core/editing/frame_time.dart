/// 帧域：时间线上的一切以**帧**为单位，毫秒只是存储格式。
///
/// 30fps 下帧点在毫秒轴上非等距（0、33、67、100、133…，间距 33/34 交替），
/// 所以任何「往前一帧」「这一段有几帧」的推导都必须回到帧序号域算，
/// 在毫秒上加减常数只会算出非帧点。
library;

/// 毫秒落在第几帧
int frameIndex(int ms, double fps) => (ms * fps / 1000).round();

/// 第 [idx] 帧的时间戳
int msOfFrame(int idx, double fps) => (idx * 1000 / fps).round();

/// 一段连续的帧，**闭区间**，与相邻段不共享任何一帧。
///
/// 台词语义单元 / 视觉镜头在存储上是 `startMs`/`endMs`，相邻两段的
/// `endMs == 下一段的 startMs`。换算成帧就是：S1 = 帧 [0, 78]、
/// S2 = 帧 [79, …]——`endMs` 那一帧属于**下一段**。播放 S1 时把它也放出来，
/// 用户看到的最后一画面就是 S2 的头。
class FrameSpan {
  /// 第一帧（含）
  final int first;

  /// 最后一帧（含）
  final int last;

  final double fps;

  const FrameSpan({required this.first, required this.last, required this.fps});

  /// 从存储用的毫秒区间 [startMs, endMs) 换算
  factory FrameSpan.fromMs(int startMs, int endMs, double fps) {
    if (!fps.isFinite || fps <= 0) {
      // 帧率非法（历史数据里出现过 ffprobe 的 0/0 被解析成 0）：
      // 退化成「一帧」，不做除零，也不产生负数
      return FrameSpan(first: 0, last: 0, fps: 1);
    }
    final first = frameIndex(startMs, fps);
    var last = frameIndex(endMs, fps);
    // endMs 未必落在帧点上（末段终点取自素材真实片长，实测 3984 / 59987 /
    // 92253 都不是帧点），所以不能直接减一：先回退到严格早于 endMs 的那一帧
    while (last > first && msOfFrame(last, fps) >= endMs) {
      last--;
    }
    return FrameSpan(first: first, last: last < first ? first : last, fps: fps);
  }

  int get frameCount => last - first + 1;

  /// 第一帧的时间戳（定位到这里就是这一段的开头）
  int get firstMs => msOfFrame(first, fps);

  /// 最后一帧的时间戳
  int get lastMs => msOfFrame(last, fps);

  /// 下一帧（即下一段的第一帧）的时间戳
  int get afterLastMs => msOfFrame(last + 1, fps);

  /// 停在最后一帧**之内**的时刻：最后一帧已完整显示，下一帧尚未开始。
  ///
  /// 播放器的「停止时间点」是个时刻而不是帧序号，落在两个帧点正中最稳妥——
  /// 取 lastMs 会因取整落到帧的起点上、取 afterLastMs 会把下一帧放出来
  /// （实测 mpv `end=2.633` 就会显示 2633 那一帧才停）。
  int get withinLastFrameMs => lastMs + (afterLastMs - lastMs) ~/ 2;

  @override
  String toString() => 'FrameSpan($first..$last @${fps}fps)';
}
