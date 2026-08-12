import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/editing/blank_unit_removal.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 删掉一个分子之后，**所有按分子下标记的东西都要跟着挪**。
///
/// 不挪的话不会报错，只会让成片悄悄变成另一个样子：原本挑给 U2 的素材跑到
/// U1 身上、配乐盖错段落。这正是「数据不能凭空错」要防的那类。
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
    test('删掉中间那个，后面的整体前移', () {
      final next = shiftReplacementsAfterRemoval(
        [
          UnitReplacement.whole(const [101]),
          UnitReplacement.whole(const [102]),
          UnitReplacement.whole(const [103]),
        ],
        removed: 1,
      );
      expect(next, hasLength(2));
      expect(next[0].wholeCandidateIds, [101]);
      expect(next[1].wholeCandidateIds, [103], reason: '原来的 U3 现在是 U2');
    });

    test('删掉第一个，后面全部前移一位', () {
      final next = shiftReplacementsAfterRemoval(
        [
          UnitReplacement.whole(const [101]),
          UnitReplacement.whole(const [102]),
        ],
        removed: 0,
      );
      expect(next.single.wholeCandidateIds, [102]);
    });

    test('删掉的位置在方案列表之外时原样返回', () {
      final before = [UnitReplacement.whole(const [101])];
      expect(shiftReplacementsAfterRemoval(before, removed: 5), same(before));
    });
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
