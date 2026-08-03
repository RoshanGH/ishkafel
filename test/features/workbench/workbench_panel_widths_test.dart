import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/workbench_panel_widths.dart';

void main() {
  group('窄窗口：先保住播放器的操作条', () {
    test('800px 时两侧收到下限，中间留给播放器', () {
      final w = workbenchPanelWidths(800);

      expect(w.left, 320,
          reason: '单元列表那一行（U3 00:27.14–00:30.08  2 镜头）在 306px '
              '以下就溢出了——实测 280 时溢出 14px');
      expect(w.right, 300);
      expect(800 - w.left - w.right, greaterThanOrEqualTo(180),
          reason: '中间再窄，播放控制条上的逐帧按钮就点不到了');
    });

    test('再窄也不会把中间挤没', () {
      final w = workbenchPanelWidths(640);

      expect(w.left + w.right, lessThan(640));
    });
  });

  group('宽窗口：多出来的宽度给面板，不留一片死黑', () {
    test('1920px 时右栏明显变宽', () {
      final w = workbenchPanelWidths(1920);

      expect(w.right, greaterThan(400),
          reason: '播放器是 9:16 竖屏，横向再宽也用不上——多出来的宽度'
              '全变成播放器两侧的死黑，而检查器里的标签和画面描述挤成一团');
      expect(w.left, greaterThan(340));
    });

    test('再宽也有上限，不让面板无限膨胀', () {
      final wide = workbenchPanelWidths(3200);
      final normal = workbenchPanelWidths(1920);

      expect(wide.right, lessThanOrEqualTo(480));
      expect(wide.right, greaterThanOrEqualTo(normal.right));
    });
  });

  test('两侧宽度随窗口单调不减（拉宽窗口时面板不该反而变窄）', () {
    var lastLeft = 0.0;
    var lastRight = 0.0;
    for (var total = 600.0; total <= 3200; total += 40) {
      final w = workbenchPanelWidths(total);
      expect(w.left, greaterThanOrEqualTo(lastLeft));
      expect(w.right, greaterThanOrEqualTo(lastRight));
      lastLeft = w.left;
      lastRight = w.right;
    }
  });
}
