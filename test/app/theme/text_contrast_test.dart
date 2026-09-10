import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/app/theme/app_colors.dart';

/// **文字要读得清。**
///
/// 2026-09-09 设计走查（设置页那段说明）：`textTertiary` 在卡片底上的
/// 对比度只有 2.65:1，远低于 WCAG AA 对正文的 4.5:1——而它在全项目有
/// 两百多处，很多是「要读的说明」，不是装饰。这个 app 是给人一天盯着
/// 干活的专业工具，字号本来就压到了 10–11px，对比度再不够就是在费眼。
///
/// 这条测试守的是**性质**，不是某个色值：换配色可以，读不清不行。
double _channel(int v) {
  final c = v / 255.0;
  return c <= 0.03928 ? c / 12.92 : _pow((c + 0.055) / 1.055, 2.4);
}

double _pow(double x, double e) {
  // dart:math 的 pow 返回 num，这里只是为了读起来干净
  var result = 1.0;
  final ln = _ln(x);
  var term = 1.0;
  final z = ln * e;
  for (var n = 1; n <= 40; n++) {
    term *= z / n;
    result += term;
  }
  return result;
}

double _ln(double x) {
  // ln(x) = 2 * artanh((x-1)/(x+1))
  final t = (x - 1) / (x + 1);
  var sum = 0.0;
  var power = t;
  for (var n = 1; n <= 99; n += 2) {
    sum += power / n;
    power *= t * t;
  }
  return 2 * sum;
}

double _luminance(Color c) {
  final r = _channel((c.r * 255).round());
  final g = _channel((c.g * 255).round());
  final b = _channel((c.b * 255).round());
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double contrast(Color fg, Color bg) {
  final a = _luminance(fg);
  final b = _luminance(bg);
  final hi = a > b ? a : b;
  final lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  /// 文字会落在这几种底上（从最深到最浅）
  const surfaces = <(String, Color)>[
    ('页面背景', AppColors.background),
    ('面板', AppColors.surface),
    ('浮起面板', AppColors.surfaceRaised),
    ('卡片', AppColors.surfaceCard),
  ];

  const texts = <(String, Color)>[
    ('主文字', AppColors.textPrimary),
    ('次要文字', AppColors.textSecondary),
    ('三级文字', AppColors.textTertiary),
  ];

  test('三级文字在每一种底上都到得了 WCAG AA（4.5:1）', () {
    final bad = <String>[];
    for (final (textName, fg) in texts) {
      for (final (bgName, bg) in surfaces) {
        final ratio = contrast(fg, bg);
        if (ratio < 4.5) {
          bad.add('$textName 在$bgName上只有 ${ratio.toStringAsFixed(2)}:1');
        }
      }
    }

    expect(bad, isEmpty,
        reason: '这些组合读不清（正文要 4.5:1）：\n${bad.join('\n')}\n'
            '本 app 的字号压到 10–11px，对比度不够就是在费眼');
  });

  test('三级之间仍分得出层级——都读得清不等于都一样重', () {
    final primary = _luminance(AppColors.textPrimary);
    final secondary = _luminance(AppColors.textSecondary);
    final tertiary = _luminance(AppColors.textTertiary);

    expect(primary / secondary, greaterThan(1.4),
        reason: '主文字和次要文字亮度太接近，层级就没了');
    expect(secondary / tertiary, greaterThan(1.4),
        reason: '次要和三级太接近，「这是说明」的暗示就消失了');
  });

  test('橙色警告文字在深色底上也读得清', () {
    // 「这 2 条素材画面上本来就烧着字」这类警告全靠它
    expect(contrast(AppColors.orange, AppColors.surfaceRaised),
        greaterThan(4.5));
  });
}
