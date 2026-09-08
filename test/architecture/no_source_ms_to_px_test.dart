import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **时间线上一格在哪儿，只能按列表下标问成片轴。**
///
/// `geometry.msToPx(原片毫秒)` 这条路已经在三处各犯了一次同样的错，
/// 而且每次的表现都不一样、都不报错：
///
/// - 绘制：原片里最后那个单元整格消失（镜头轨还画着，单元轨是空的）
/// - 播放：双击它，播放区间变成「从 104 秒播到 0 秒」，什么也放不出来
/// - 命中：那一格根本点不中，选中态停在上一格
///
/// 病根都是 `endMs` 是开区间，而「原片毫秒 → 成片毫秒」按「谁的原片区间盖住
/// 它」找——它落进的是**相邻那一段**。列表顺序和原片顺序一致时两者正好相等，
/// 所以平时看不出来；手加的单元一被拖到最前就全露馅（2026-09-08 真机）。
void main() {
  test('绘制与命中都不再拿单元/镜头的原片毫秒去换算像素', () {
    // 只允许两处：_unitPx 和 _shotPx 里「没有成片轴时」的兜底。
    // 用计数而不是「在不在助手里」——后者要靠猜函数边界，猜错了守卫就形同
    // 虚设（第一版就是这样，把接线改回旧写法它照样绿）。
    const allowedPerFile = 4;  // _unitPx 与 _shotPx 各 2 处兜底
    const files = [
      'lib/features/workbench/timeline/timeline_painter.dart',
      'lib/features/workbench/timeline/timeline_hit_tester.dart',
    ];

    for (final path in files) {
      final src = File(path).readAsStringSync();
      final hits = RegExp(r'msToPx\((?:unit|shot|units\[[^\]]+\])[^)]*\)')
          .allMatches(src)
          .map((m) => m.group(0)!)
          .toList();

      expect(hits.length, lessThanOrEqualTo(allowedPerFile),
          reason: '$path 里有 ${hits.length} 处拿原片毫秒换算像素'
              '（只该有 $allowedPerFile 处兜底）：\n${hits.join('\n')}\n'
              '顺序一乱就会算到别的段上，改成 _unitPx(下标) / '
              '_shotPx(单元下标, 镜头下标)');
    }
  });

  test('双击播放传的是下标，不是毫秒', () {
    final src =
        File('lib/features/workbench/timeline/timeline_view.dart')
            .readAsStringSync();

    expect(src, contains('void Function(int unitIndex, int? shotIndex)?'),
        reason: '传毫秒的话上层还得换算一次，又会踩同一个坑');
  });
}
