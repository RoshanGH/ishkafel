import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/workbench_panel_widths.dart';

void main() {
  group('挑素材时把播放器两侧的死黑还给候选面板', () {
    test('1600×533 的工作区：播放器只需要约 300 宽，其余归面板', () {
      final w = workbenchPanelWidths(1600,
          stageHeight: 533, candidatesActive: true);

      // 9:16 竖屏在 533 高（减去控制条）下只要 ~270 宽，剩下六百多是死黑
      expect(w.right, greaterThan(800),
          reason: '此前右栏封顶 480，候选网格一屏只有六个格子');
      expect(1600 - w.left - w.right, greaterThanOrEqualTo(280),
          reason: '播放器仍要放得下 9:16 画面和控制条');
    });

    test('看检查器时不这么撑——它是表单，太宽反而难读', () {
      final w = workbenchPanelWidths(1600,
          stageHeight: 533, candidatesActive: false);

      expect(w.right, lessThanOrEqualTo(480));
    });

    test('窄窗口下候选面板也不能把播放器挤没', () {
      final w = workbenchPanelWidths(900,
          stageHeight: 400, candidatesActive: true);

      expect(900 - w.left - w.right, greaterThanOrEqualTo(280),
          reason: '挤到点不中逐帧按钮，挑完素材就没法核对了');
      expect(w.right, greaterThanOrEqualTo(300));
    });

    test('工作区矮的时候播放器需要的宽度也小，面板能更宽', () {
      final tall = workbenchPanelWidths(1600,
          stageHeight: 700, candidatesActive: true);
      final short = workbenchPanelWidths(1600,
          stageHeight: 400, candidatesActive: true);

      expect(short.right, greaterThan(tall.right),
          reason: '播放器宽度是按 9:16 从高度推出来的，矮就窄');
    });

    test('不给高度时退回原来的按比例分配——老调用点不受影响', () {
      final w = workbenchPanelWidths(1600);

      expect(w.right, lessThanOrEqualTo(480));
      // 1600×0.18=288，落在下限上
      expect(w.left, 320);
    });

    test('拉宽窗口时候选面板不会反而变窄', () {
      var last = 0.0;
      for (var total = 900.0; total <= 3200; total += 40) {
        final w = workbenchPanelWidths(total,
            stageHeight: 533, candidatesActive: true);
        expect(w.right, greaterThanOrEqualTo(last));
        last = w.right;
      }
    });
  });
}
