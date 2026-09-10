import 'package:flutter/material.dart';

/// 底部渐隐：内容还没到底时，在下沿压一层淡出，告诉人「还有，往下滚」。
///
/// 2026-09-09 设计走查：属性面板里「单元台词（可编辑）」和「拆分 / 并入」
/// 落在可视区外，而 macOS 的滚动条是 overlay 式的——不动鼠标它根本不出现。
/// 于是人看不到那两样东西，等于这个面板少了一半功能，还完全没有线索。
///
/// 渐隐层自己的 key，测试据此认人（[ListView] 内部也有 IgnorePointer）
const scrollFadeKey = ValueKey('scroll-fade');

/// [child] 必须是一个可滚动的东西（[ListView] / [SingleChildScrollView]）。
/// [background] 给渐隐的落地色，要和这一栏的底色一致，否则会看出一条脏边。
class ScrollFade extends StatefulWidget {
  final Widget child;
  final Color background;

  /// 渐隐带的高度
  final double height;

  const ScrollFade({
    super.key,
    required this.child,
    required this.background,
    this.height = 28,
  });

  @override
  State<ScrollFade> createState() => _ScrollFadeState();
}

class _ScrollFadeState extends State<ScrollFade> {
  bool _more = false;

  /// **不能在通知回调里直接 setState**：滚动通知是在布局/绘制过程里发出来的，
  /// 那一刻标脏会撞上 "setState() called during build"
  bool _sync(ScrollMetrics metrics) {
    if (!metrics.hasContentDimensions) return false;
    final more = metrics.extentAfter > 2;
    if (more == _more) return false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _more = more);
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) => _sync(n.metrics),
      // 内容变高但没人滚动时也要更新：首次布局、以及切换选中之后
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) => _sync(n.metrics),
        child: Stack(
          children: [
            widget.child,
            if (_more)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    key: scrollFadeKey,
                    height: widget.height,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          widget.background.withValues(alpha: 0),
                          widget.background,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
