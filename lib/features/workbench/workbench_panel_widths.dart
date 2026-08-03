import 'dart:math' as math;

/// 工作台三栏中两侧面板的宽度
class WorkbenchPanelWidths {
  final double left;
  final double right;
  const WorkbenchPanelWidths({required this.left, required this.right});
}

/// 按窗口宽度分配两侧面板的宽度。
///
/// 为什么不写死：素材是 9:16 竖屏，播放器横向再宽也用不上——窗口一拉宽，
/// 多出来的几百像素全变成播放器两侧的死黑，而检查器里的标签 chips 和画面
/// 描述却挤成一团。多出来的宽度应该给面板。
///
/// 反过来，窄窗口下必须先保住中间：两侧一旦把中间挤到两百像素以下，播放
/// 控制条上的逐帧按钮就点不到了（改造时踩过：右栏从 300 加到 320，测试用的
/// 800px 窗口里逐帧按钮直接点不中）。所以两侧都有下限，且下限之和远小于
/// 任何可用窗口宽度。
WorkbenchPanelWidths workbenchPanelWidths(double totalWidth) {
  double band(double ratio, double min, double max) =>
      math.min(max, math.max(min, totalWidth * ratio));

  // 下限 320 不是拍脑袋：单元列表行里「U3 00:27.14–00:30.08  2 镜头」这一行
  // 在 306px 以下就会溢出（实测 280 时溢出 14px）
  final left = band(0.18, 320, 400);
  final right = band(0.24, 300, 480);
  // 极窄窗口的兜底：两侧之和不能吃掉整行。0.8 而不是更小——800px（测试与
  // 小窗常见尺寸）下两侧正好是 320+300=620，占 0.775，必须让下限赢过这条
  // 兜底，否则单元列表又会溢出。真正窄到 700 以下才按比例缩。
  final budget = totalWidth * 0.8;
  if (left + right <= budget) {
    return WorkbenchPanelWidths(left: left, right: right);
  }
  final scale = budget / (left + right);
  return WorkbenchPanelWidths(left: left * scale, right: right * scale);
}
