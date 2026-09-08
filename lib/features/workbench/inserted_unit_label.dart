/// 属性栏上「时长」那一格该写什么。
///
/// 三个来源要分清楚：
/// - [placeholderMs]：单元自己的 `endMs - startMs`。对分析切出来的单元它就是
///   原片那一段的真实长度；对**手加的**单元它只是加进来时给的占位（10 秒），
///   不是任何真实的长度
/// - [composedMs]：这一段在成片里真正占多长（被整体替换时跟着候选走）。
///   时间线画的就是它
/// - [hasSource]：这个单元在原片上有没有对应的一段
///
/// 真机 bug（2026-09-07）：这里一直只报 [placeholderMs]，于是手加的单元
/// 属性栏写着 10.00s、时间线上却是素材的真实长度——同一个东西两处说法不一样，
/// 人只会以为哪儿算错了。而「待填」那种情况报 10 秒更糟：他会照着它规划片长。
String unitDurationLabel({
  required int placeholderMs,
  required int? composedMs,
  required bool hasSource,
}) {
  if (composedMs != null && composedMs > 0) return _seconds(composedMs);
  // 原片上没有它、又还没挑素材：这一段现在没有任何真实长度可言
  if (!hasSource) return '待填';
  return _seconds(placeholderMs);
}

String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(2)}s';
