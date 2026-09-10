import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// 浮起的一层：上沿一线高光 + 可选的落影。
///
/// macOS 里几乎每个浮起的面板都有这道高光——光从上方来，上沿被照亮一线。
/// 少了它，深色块就是一片死板的纯色；有了它，层与层之间立刻分得开，
/// 也才有「材质」而不只是「颜色」（2026-09-10 走查，产品负责人原话
/// 「现在太不好看了」）。
///
/// 只画上沿：四边都描一圈会变成「框」，那是另一种东西（选中态才用框）。
class RaisedSurface extends StatelessWidget {
  final Widget child;

  /// 这一层自己的底色
  final Color color;

  final BorderRadiusGeometry? borderRadius;

  /// 要不要托一层影。贴着地面的面板不用，真正浮起来的（卡片、浮层）才用
  final bool shadow;

  final EdgeInsetsGeometry? padding;

  const RaisedSurface({
    super.key,
    required this.child,
    required this.color,
    this.borderRadius,
    this.shadow = false,
    this.padding,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          // 高光走渐变，不走描边：Flutter 不允许「有圆角时四边异色」
          gradient: topLit(color),
          borderRadius: borderRadius,
          boxShadow: shadow
              ? const [
                  BoxShadow(
                      color: Color(0x4D000000),
                      blurRadius: 12,
                      offset: Offset(0, 3)),
                ]
              : null,
        ),
        child: child,
      );
}
