import 'subtitle_style.dart';

/// 我们这一行字落在画面的哪个矩形（归一化 0~1，原点在左上角）。
///
/// **为什么要算它**：「字幕位置合不合适」原本只有看图才知道。
/// 有了这个矩形，等素材烧字的矩形也到手之后（要动 AI 识图，另立一波），
/// 「合不合适」就降维成「两个矩形重不重叠」——一个事实，不是判断。
class CaptionBox {
  final double left;
  final double right;
  final double top;
  final double bottom;

  /// 这个字号下一屏最多放几个字
  final int maxCharsPerScreen;

  /// 这一行超了，会被自动切成两屏。**这是事实，要说出来**——
  /// 人看成片时会发现节奏碎掉，而它不出现在任何错误日志里
  final bool willWrap;

  const CaptionBox({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.maxCharsPerScreen,
    required this.willWrap,
  });
}

/// 左右留 8% 余量，与 [SubtitleStyle.maxCharsPerScreen] 的算法同源
const double _sideMargin = 0.08;

CaptionBox captionBoxOf({
  required SubtitleStyle style,
  required String text,
}) {
  // bottomRatio 量的是**距画面底部**的比例；换成从上往下的坐标要反过来
  final bottom = 1 - style.bottomRatio;
  final cap = style.maxCharsPerScreen;
  return CaptionBox(
    left: _sideMargin,
    right: 1 - _sideMargin,
    top: bottom - style.fontRatio,
    bottom: bottom,
    maxCharsPerScreen: cap,
    willWrap: text.runes.length > cap,
  );
}
