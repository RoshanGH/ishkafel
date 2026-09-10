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
    // 主按钮托一层**自己颜色的辉光**。
    //
    // 2026-09-10 走查：「进入矩阵导出」「新建任务」这些主动作原来就是一块
    // 扁平的纯蓝，跟旁边的描边按钮放在一起，主次全靠颜色撑——按钮不像
    // 「可以按下去的东西」（产品负责人：「现在太不好看了」）。
    // 蓝色阴影而不是黑色：深色界面里黑影看不见，同色辉光才托得起来。
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 3,
        shadowColor: AppColors.accentBlue.withValues(alpha: 0.45),
      ),
    ),
    // 次要按钮：描边比原来实一点，别虚到看不见是个按钮
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: AppColors.border),
        foregroundColor: AppColors.textPrimary,
      ),
    ),
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
