import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/app/theme/app_spacing.dart';
import 'package:ishkafel/app/theme/app_typography.dart';

void main() {
  group('间距 token 守住 4pt 网格（CLAUDE.md 设计标准）', () {
    test('每个间距值都是 4 的倍数', () {
      for (final v in AppSpacing.all) {
        expect(v % 4, 0,
            reason: '间距 $v 不在 4pt 网格上，会破坏整体视觉节奏');
      }
    });

    test('间距阶梯严格递增且无重复', () {
      for (var i = 1; i < AppSpacing.all.length; i++) {
        expect(AppSpacing.all[i], greaterThan(AppSpacing.all[i - 1]),
            reason: '阶梯必须严格递增，否则相邻两级没有可辨的层级差');
      }
    });

    test('圆角与描边取值克制（HIG：避免过度装饰）', () {
      expect(AppRadius.lg, lessThanOrEqualTo(12),
          reason: '最大圆角超过 12 会显得圆润廉价，偏离专业工具的观感');
      expect(AppStroke.emphasis, greaterThan(AppStroke.hairline));
    });
  });

  group('字号阶梯 token', () {
    test('相邻两级至少相差 1px（0.5px 的差别读不出层级）', () {
      for (var i = 1; i < AppFontSize.all.length; i++) {
        expect(AppFontSize.all[i] - AppFontSize.all[i - 1],
            greaterThanOrEqualTo(1.0),
            reason: '${AppFontSize.all[i - 1]} 与 ${AppFontSize.all[i]} '
                '之间差别太小，只会让排版发糊');
      }
    });

    test('阶梯严格递增，且最小字号不低于 10（macOS 下的可读下限）', () {
      for (var i = 1; i < AppFontSize.all.length; i++) {
        expect(AppFontSize.all[i], greaterThan(AppFontSize.all[i - 1]));
      }
      expect(AppFontSize.all.first, greaterThanOrEqualTo(10.0));
    });
  });
}
