import 'package:flutter/material.dart';

/// HIG 暗色色板（值来源：项目 CLAUDE.md 设计标准）
abstract final class AppColors {
  static const background = Color(0xFF131316);
  static const surface = Color(0xFF1E1E20);
  static const surfaceRaised = Color(0xFF232326);
  static const surfaceCard = Color(0xFF2C2C2E);
  static const border = Color(0x17FFFFFF); // 白 9%
  static const accentBlue = Color(0xFF0A84FF);
  /// accentBlue 的高亮变体：用于 accentBlue 半透明底上的文字（如标签 chip），
  /// 保证在深色 tint 底上的对比度。
  static const accentBlueLight = Color(0xFF64A8FF);
  static const green = Color(0xFF30D158);
  static const orange = Color(0xFFFF9F0A);
  static const red = Color(0xFFFF453A);
  static const purple = Color(0xFFBF5AF2);
  static const textPrimary = Color(0xFFF2F2F7);
  static const textSecondary = Color(0xFF98989F);
  static const textTertiary = Color(0xFF636366);

  /// 播放器舞台底色：视频画面区域背后的纯黑背景，与其余暗色层级区分，
  /// 让内容（画面/占位图标）在舞台内保持最高对比度。
  static const stageBackground = Color(0xFF000000);
}
