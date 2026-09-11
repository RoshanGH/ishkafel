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

/// 把人敲进去的时间码读回毫秒。**认不出来返回 null**——猜一个数出来，
/// 人看到的就是「我明明输的不是这个」。
///
/// 认这几种写法（帧位一律按 [fps] 换算，不是百分之一秒）：
/// `00:17.10`、`17.10`、`00:17`、`17`。冒号允许全角，前后空格无所谓。
///
/// 帧号超出这一秒的范围时**夹到满帧**，不进位：人敲 `.30`（30fps 下没有
/// 第 30 帧）多半是想要「这一秒的最后」，跳成下一秒整会让他以为输错了地方。
int? parseTimecode(String raw, double fps) {
  final fpsRound = fps.round();
  if (fpsRound <= 0) return null;
  final text = raw.trim().replaceAll('：', ':');
  if (text.isEmpty) return null;
  final m = RegExp(r'^(?:(\d{1,3}):)?(\d{1,2})(?:\.(\d{1,2}))?$')
      .firstMatch(text);
  if (m == null) return null;
  final minutes = int.parse(m.group(1) ?? '0');
  final seconds = int.parse(m.group(2)!);
  final frames = int.parse(m.group(3) ?? '0').clamp(0, fpsRound - 1);
  return ((minutes * 60 + seconds) * 1000) + (frames * 1000 ~/ fpsRound);
}

/// 帧率写给人看：`30fps` / `29.97fps`。整数不拖小数尾巴
String fpsLabel(double fps) {
  if (fps <= 0) return '未知帧率';
  final text = fps == fps.roundToDouble()
      ? '${fps.round()}'
      : fps.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
  return '${text}fps';
}

/// 时间码的**自报家门**。
///
/// `00:17.28` 里的 `.28` 是**帧号**，不是百分之一秒——30fps 下它等于
/// 17.933 秒，按小数读会差出 0.65 秒。界面上不写清楚，人一定会读错
/// （2026-09-11 用户原话：「这对我造成了很大的困扰，我不理解这个东西」）。
///
/// 所以凡是摆时间码的地方都要带上这一句：格式 + 帧率 + 一个当场能对照的例子。
String timecodeLegend(double fps) {
  final fpsRound = fps.round();
  if (fpsRound <= 0) return '时间码 分:秒.帧';
  // 例子用一个不可能被误读成小数的帧号：帧率减二，30fps 下是 28
  final ff = fpsRound > 2 ? fpsRound - 2 : fpsRound - 1;
  return '时间码 分:秒.帧 · ${fpsLabel(fps)}'
      '（00:17.${_pad2(ff)} = 17 秒第 $ff 帧）';
}

String _pad2(int n) => n.toString().padLeft(2, '0');
