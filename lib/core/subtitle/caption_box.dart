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

  /// 这一行这个字号一屏放不下，**会在画面上折成两行、同时挂着**。
  /// 这是事实，要说出来——人看成片时一眼就看见两层字，而它不出现在
  /// 任何错误日志里。
  ///
  /// **不是「切成两屏先后显示」。** 替换裂变的导出走 `SubtitleRasterizer`
  /// （`export_runner.dart` 里 `rasterizer.rasterize`），AppKit 按给定宽度
  /// 折行；`subtitleScreensAt` 那套「切成两屏」只在剪映草稿和脚本成片那条
  /// 线用，替换裂变不走那条路。说成「切成两屏」，人会以为不影响观感——
  /// 2026-09-20 真机核实过这处文案说的是假话
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

/// 左右各留 5.5% 的余量。
///
/// **这个数必须跟真正光栅化时用的那个一致**：
/// `lib/core/subtitle/subtitle_rasterizer.dart` 里
/// `const margin = Math.round(w * 0.055)`——那是字真的会被画在哪儿。
/// 原来写的 0.08 是照 [SubtitleStyle.maxCharsPerScreen] 的容量估算抄的，
/// 左右各差 2.5% 画面宽；这个矩形是拿来跟素材烧字的 bbox 比重叠的，
/// 差一点就白算。**改动任意一处都要同步另一处**，
/// `caption_box_test.dart` 会从光栅化那边现抓这个数来核对。
///
/// 容量那条公式（`maxCharsPerScreen` 用 8%）没跟着改：它估的是「一屏放得下
/// 几个字」，宽松一点只会早一点报折行，不影响矩形位置。
const double _sideMargin = 0.055;

CaptionBox captionBoxOf({
  required SubtitleStyle style,
  required String text,
}) {
  // bottomRatio 量的是**距画面底部**的比例；换成从上往下的坐标要反过来
  final bottom = 1 - style.bottomRatio;
  final cap = style.maxCharsPerScreen;
  // top 要按真实行数退，不是永远按一行。这个矩形是拿来跟素材烧字的 bbox
  // 比重叠的，高度少算一整行，恰好少在最可能打架的那种情形上——
  // 真机 U2S3：字号 0.065、一屏 7 字、这一段 10 个字，实际上沿约在 0.37，
  // 报的却是 0.435
  final lineCount =
      cap <= 0 ? 1 : (text.runes.length / cap).ceil().clamp(1, 99);
  return CaptionBox(
    left: _sideMargin,
    right: 1 - _sideMargin,
    top: bottom - style.fontRatio * lineCount,
    bottom: bottom,
    maxCharsPerScreen: cap,
    willWrap: text.runes.length > cap,
  );
}
