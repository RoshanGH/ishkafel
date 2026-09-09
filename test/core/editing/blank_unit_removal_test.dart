import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/editing/blank_unit_removal.dart';

/// 删掉一个单元之后，**配乐区间要跟着收缩**。
///
/// 别的东西（替换方案、配音、手改字幕）都按单元自己的身份记，删一个单元
/// 只是「这个身份没了」，剩下的一份都不动。配乐记的是**区间**（哪几段连着
/// 铺一首曲子），删掉中间一段会改变「这一段盖住谁」，只有它要重新算。
void main() {
  BgmPlan planWith(List<(int, int)> ranges) {
    var plan = BgmPlan.empty;
    for (final (start, end) in ranges) {
      plan = plan.assign(
        startUnit: start,
        endUnit: end,
        materials: [
          BgmMaterial(
              id: start,
              name: '曲$start',
              durationMs: 30000,
              previewUrl: 'https://example.invalid/$start.mp3'),
        ],
        rangeMs: 10000,
      );
    }
    return plan;
  }

  group('替换方案跟着挪', () {


  });

  group('配乐区间跟着挪', () {
    test('删掉区间后面的分子，区间不动', () {
      final next = shiftBgmAfterRemoval(planWith([(0, 1)]), removed: 3);
      expect(next.segments.single.startUnit, 0);
      expect(next.segments.single.endUnit, 1);
    });

    test('删掉区间前面的分子，整段前移', () {
      final next = shiftBgmAfterRemoval(planWith([(2, 3)]), removed: 0);
      expect(next.segments.single.startUnit, 1);
      expect(next.segments.single.endUnit, 2);
    });

    test('删掉区间中间的分子，区间缩短一格', () {
      final next = shiftBgmAfterRemoval(planWith([(0, 2)]), removed: 1);
      expect(next.segments.single.startUnit, 0);
      expect(next.segments.single.endUnit, 1);
    });

    test('区间只剩这一个分子时整段删掉——不能留一段盖着空气的配乐', () {
      final next = shiftBgmAfterRemoval(planWith([(1, 1)]), removed: 1);
      expect(next.segments, isEmpty);
    });
  });
}
