/// 帧序号域算术——全项目**唯一**一份。
///
/// 为什么必须回到帧序号域：30fps 下帧点在毫秒轴上非等距（0、33、67、100、
/// 133…，间距在 33/34ms 之间交替）。「往前一帧」用 ms 域常数偏移
/// （ms - 1000/fps）会算出非帧点，进而产生半帧的边界或对不上的画面。
///
/// 切分编辑（[SegmentationEditOps]）与片段播放共用这里，两处规则一旦分叉，
/// 时间线上画出来的边界和播放器实际停的位置就会对不上。
library;

int frameIndex(int ms, double fps) => (ms * fps / 1000).round();

int msOfFrame(int idx, double fps) => (idx * 1000 / fps).round();

/// 严格小于 [endMs] 的最大帧点，即「以 [endMs] 为终点（半开区间）的片段的
/// 最后一帧」。
///
/// 相邻的台词语义单元 / 视觉镜头是无缝覆盖的半开区间：S1 = [0, 2000)、
/// S2 = [2000, 5000)。因此 `endMs` **就是下一段的第一帧**——播到 endMs 才停
/// 等于让用户双击 S1 却看到 S2 的画面。
///
/// [endMs] 未必落在帧点上（末段的终点取自素材真实片长，是外部数据），
/// 所以不能简单地「帧序号减一」：那样在 endMs 非帧点时会多退一帧。这里
/// 先取最接近的帧序号，再逐步回退到严格小于 endMs 为止。
int lastFrameBefore(int endMs, double fps) {
  if (endMs <= 0) return 0;
  // 帧率非法（历史遗留数据里出现过 ffprobe 的 0/0 被解析成 0）时不做除零，
  // 退回「终点前 1ms」这个虽不精确但绝不会更糟的结果
  if (!fps.isFinite || fps <= 0) return endMs - 1;

  var idx = frameIndex(endMs, fps);
  while (idx > 0 && msOfFrame(idx, fps) >= endMs) {
    idx--;
  }
  final ms = msOfFrame(idx, fps);
  // fps 极低时第 0 帧也可能 >= endMs（例如 1fps、endMs=1）
  return ms < endMs ? ms : endMs - 1;
}
