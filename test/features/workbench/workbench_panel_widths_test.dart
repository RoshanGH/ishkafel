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

      // 上限跟着窗口涨，但涨得慢也封得住：表单行太长反而难读
      expect(wide.right, lessThanOrEqualTo(620));
      expect(wide.left, lessThanOrEqualTo(760));
      expect(wide.right, greaterThanOrEqualTo(normal.right));
    });

    test('1440 这档常用尺寸不受影响——上限还没被比例追上', () {
      final w = workbenchPanelWidths(1440, stageHeight: 500);

      expect(w.left, 560);
      expect(w.right, 480);
    });
  });

  group('属性面板也吃掉播放器两侧的死黑', () {
    // 2026-09-09 设计走查：1440 窗口、属性 tab 下，中栏 775px 里画面只占
    // 211px，两侧 560px 是纯黑。而左栏的台词「早就跟你们说了，我长痘就是
    // 全家衣服混洗有细菌…」被截断、右栏的表单也挤着。
    //
    // 原来只在挑素材时才把这片空间还回去（candidatesActive），理由是
    // 「检查器是表单，行太长反而难读」——但那只说明它该有上限，
    // 不说明多出来的那半屏就只能是黑的。
    test('1440 窗口下两侧都到上限，中栏收窄', () {
      final w = workbenchPanelWidths(1440, stageHeight: 500);

      expect(w.left, 560, reason: '左栏该吃到上限，台词才不会被截断');
      expect(w.right, 480, reason: '右栏是表单，行太长反而难读');
      expect(1440 - w.left - w.right, lessThanOrEqualTo(400),
          reason: '中栏原来 775px 里有 560px 是死黑');
    });

    test('中栏永远留得下播放控制条', () {
      // 800 及以下两侧本来就在下限上（320+300），中栏只能是剩下的那点，
      // 那是窄窗口的已知取舍（见上面那组）；这里盯的是正常尺寸
      for (final total in [1000.0, 1280.0, 1440.0, 1920.0, 2560.0]) {
        final w = workbenchPanelWidths(total, stageHeight: 500);
        expect(total - w.left - w.right, greaterThanOrEqualTo(280),
            reason: '$total 下中栏被挤到 ${total - w.left - w.right}，'
                '逐帧按钮就点不中了');
      }
    });

    test('挑素材时候选面板仍然优先——它要的是「一屏几个格子」', () {
      final picking =
          workbenchPanelWidths(1920, stageHeight: 500, candidatesActive: true);
      final inspecting = workbenchPanelWidths(1920, stageHeight: 500);

      expect(picking.right, greaterThan(inspecting.right));
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
