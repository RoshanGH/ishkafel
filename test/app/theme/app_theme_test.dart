import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/app/theme/app_colors.dart';
import 'package:ishkafel/app/theme/app_theme.dart';

void main() {
  test('色板符合 CLAUDE.md 定义的 HIG 暗色标准', () {
    expect(AppColors.background, const Color(0xFF0B0B0D));
    expect(AppColors.surface, const Color(0xFF17171A));
    expect(AppColors.surfaceRaised, const Color(0xFF202024));
    expect(AppColors.surfaceCard, const Color(0xFF2A2A30));
    expect(AppColors.accentBlue, const Color(0xFF0A84FF));
    expect(AppColors.green, const Color(0xFF30D158));
    expect(AppColors.orange, const Color(0xFFFF9F0A));
    expect(AppColors.red, const Color(0xFFFF453A));
    expect(AppColors.purple, const Color(0xFFBF5AF2));
    expect(AppColors.textPrimary, const Color(0xFFF2F2F7));
    // 这两级比 macOS 系统的 secondaryLabel/tertiaryLabel 亮一档：
    // 苹果那两个色只用来画 disabled 和装饰，而这里拿它们写「要读的说明」。
    // 真正守着的是对比度，见 text_contrast_test.dart
    expect(AppColors.textSecondary, const Color(0xFFAEAEB6));
    expect(AppColors.textTertiary, const Color(0xFF949499));
  });

  test('主题为暗色且主色为系统蓝', () {
    final theme = buildAppTheme();
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, AppColors.accentBlue);
    expect(theme.scaffoldBackgroundColor, AppColors.background);
  });
}
