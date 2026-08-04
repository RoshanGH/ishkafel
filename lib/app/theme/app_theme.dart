import 'package:flutter/material.dart';
import 'app_colors.dart';

ThemeData buildAppTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accentBlue,
      surface: AppColors.surface,
      error: AppColors.red,
    ),
    scaffoldBackgroundColor: AppColors.background,
    fontFamilyFallback: const ['PingFang SC', 'Microsoft YaHei'],
  );
  return base.copyWith(
    cardTheme: const CardThemeData(color: AppColors.surfaceRaised),
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1),
    // 页面转场统一用淡入，不用平台默认。
    //
    // macOS 上 Flutter 默认给的是 Cupertino 转场，它自带「从左边缘往右拖 =
    // 返回上一页」，热区是紧贴窗口左边缘的一条 20pt。而工作台的时间线正好贴
    // 着左边缘：在配乐轨最左端（00:00 附近）横向拖选一段镜头，就落在那条热区
    // 里——用户看到的是整个工作台被拖走、露出后面的任务列表。
    //
    // 这是台桌面应用，返回靠顶栏那个箭头，边缘手势本来也不属于这里。
    pageTransitionsTheme: PageTransitionsTheme(builders: {
      for (final platform in TargetPlatform.values)
        platform: const FadeUpwardsPageTransitionsBuilder(),
    }),
  );
}
