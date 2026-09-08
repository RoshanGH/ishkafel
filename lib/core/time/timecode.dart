/// 时间码与帧对齐。**全 app 只有这一处格式化时间。**
///
/// 原来这两件事挂在 `inspector_panel.dart` 上，于是命令行、导出、报告想显示
/// 时间就得去 import 一个界面文件——要么绕过它自己拼一份，两边迟早不一样。
library;

/// 毫秒 → `分:秒.帧`（如 `01:36.07` = 1 分 36 秒第 7 帧）。
///
/// **帧位不是百分之一秒**：`00:45.03` 是 45 秒第 3 帧，30fps 下等于 45.100s。
/// 项目要求时间显示精确到帧（见 CLAUDE.md 帧对齐一节）——秒的小数位读不出
/// 「差几帧」，而拖边界、步进都是按帧走的。
///
/// 实现上的两个讲究：
///
/// 帧号先把 ms 换算为总帧数再四舍五入取整，而不是直接对 `ms % 1000` 做浮点
/// 运算截断：例如 70033ms/30fps 精确对应第 2101 帧（70.033*30=2100.99，
/// 四舍五入为 2101），落在第 70 秒的第 1 帧上，若直接对毫秒余数取整会因浮
/// 点误差把这一帧算漏、显示成 00 帧。
///
/// `fps.round()` 用作 mm:ss 的秒数除数是显示层的可接受近似：非整数帧率
/// （如 29.97）下会有亚帧级漂移，但不会导致 ff 达到/超过 fpsRound（帧号
/// 始终落在 [0, fpsRound) 内），因此只影响显示，不影响编辑运算的帧精度
/// （编辑运算走 SegmentationEditOps.frameMs，独立于这里的显示格式化）。
String formatTimecode(int ms, double fps) {
  final fpsRound = fps.round();
  if (fpsRound <= 0) return '00:00.00';
  final totalFrames = (ms * fps / 1000).round();
  final totalSeconds = totalFrames ~/ fpsRound;
  final ff = totalFrames % fpsRound;
  final mm = totalSeconds ~/ 60;
  final ss = totalSeconds % 60;
  return '${_pad2(mm)}:${_pad2(ss)}.${_pad2(ff)}';
}

/// 把毫秒吸到最近的帧边界上。
///
/// 手加的台词语义单元长度是人给的（比如「10 秒」），不落在帧边界上的话，
/// 它后面每一段的成片位置都会带着这个零头往下传，拼到片尾越差越多——
/// 而界面显示的是帧，人看到的就是「明明每段都对，加起来差了一帧」。
///
/// [fps] 不合法时原样返回：读不出帧率不该让时间凭空变一下。
int alignToFrame(int ms, double fps) {
  if (fps <= 0) return ms;
  return ((ms * fps / 1000).round() * 1000 / fps).round();
}

String _pad2(int n) => n.toString().padLeft(2, '0');
