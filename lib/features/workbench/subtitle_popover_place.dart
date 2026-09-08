import 'dart:ui';

/// 双击字幕块弹出的浮层摆在哪儿。**纯函数，可单测**。
///
/// 用户要的是「在那个地方改」（2026-09-08）。但字幕轨只有 22px 高、窄镜头的
/// 块可能只有几十像素宽——把块体本身变成输入框做不出能用的东西。所以改成弹
/// 一个定宽的浮层贴着它。
///
/// **高度不由这里定死**：内容有几行是外面才知道的，估小了会把「加一段」挤到
/// 可视区外，点下去落到遮罩上、浮层直接关掉（写这条时就踩到了）。这里只给出
/// 「贴哪条边、最多能有多高」，让浮层按内容自己长。
class SubtitlePopoverSpot {
  final double left;

  /// 摆在块体**上方**时：浮层的下边贴在这儿（离屏幕顶多远）。
  /// 用下边定位，内容变多时它往上长，不会离开块体
  final double? bottom;

  /// 摆在块体**下方**时：浮层的上边贴在这儿
  final double? top;

  /// 这一侧最多能给多高。超过就在浮层内部滚，不会溢出屏幕
  final double maxHeight;

  const SubtitlePopoverSpot({
    required this.left,
    required this.maxHeight,
    this.top,
    this.bottom,
  });

  bool get isAbove => bottom != null;
}

/// 摆放规则：
/// - **优先摆在块体上方**：字幕轨下面还有配乐、画面、音频三条轨，往下弹会把
///   它们盖住；而上方是镜头轨与单元轨，人此刻的注意力本来就在那儿。
/// - 上方余量不如下方时翻到下方。
/// - 横向以块体中心对齐，再夹回屏幕内——窄块体在屏幕边缘时，居中会让半个
///   浮层跑到屏幕外。
SubtitlePopoverSpot placeSubtitlePopover({
  /// 块体在屏幕坐标系里的位置
  required Rect anchor,
  required Size screen,
  required double width,

  /// 浮层与块体之间留的缝，也用作贴边时的最小留白
  double gap = 8,
}) {
  var left = anchor.center.dx - width / 2;
  left = left.clamp(gap, (screen.width - width - gap).clamp(gap, double.infinity));

  final roomAbove = anchor.top - gap * 2;
  final roomBelow = screen.height - anchor.bottom - gap * 2;

  if (roomAbove >= roomBelow) {
    return SubtitlePopoverSpot(
      left: left,
      bottom: screen.height - (anchor.top - gap),
      maxHeight: roomAbove.clamp(0, double.infinity),
    );
  }
  return SubtitlePopoverSpot(
    left: left,
    top: anchor.bottom + gap,
    maxHeight: roomBelow.clamp(0, double.infinity),
  );
}
