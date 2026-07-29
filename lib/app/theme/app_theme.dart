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
  );
}
