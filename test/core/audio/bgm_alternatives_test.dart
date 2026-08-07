import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';

BgmMaterial _m(int id, String name) =>
    BgmMaterial(id: id, name: name, durationMs: 30000, previewUrl: 'u$id');

final _a = _m(1, 'A');
final _b = _m(2, 'B');
final _c = _m(3, 'C');

void main() {
  group('一段配乐可以选多首，它们互为备选（不是叠着放）', () {
    test('导出时按变体序号轮流取，用完一轮回到头', () {
      final plan = BgmPlan.empty.assign(
          startUnit: 0,
          endUnit: 1,
          materials: [_a, _b, _c],
          rangeMs: 10000);
      final seg = plan.segments.single;

      expect(seg.materialFor(0).name, 'A');
      expect(seg.materialFor(1).name, 'B');
      expect(seg.materialFor(2).name, 'C');
      expect(seg.materialFor(3).name, 'A', reason: '用完一轮回到头');
      expect(seg.materialFor(4).name, 'B');
    });

    test('只选一首时每条变体都用它', () {
      final seg = BgmPlan.empty
          .assign(startUnit: 0, endUnit: 0, materials: [_a], rangeMs: 5000)
          .segments
          .single;

      expect(seg.materialFor(0).name, 'A');
      expect(seg.materialFor(7).name, 'A');
    });

    test('各段各自轮各自的——第二段只有一首就一直是它', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, materials: [_a, _b, _c], rangeMs: 1)
          .assign(startUnit: 2, endUnit: 2, materials: [_b], rangeMs: 1);

      expect(plan.segments[0].materialFor(1).name, 'B');
      expect(plan.segments[1].materialFor(1).name, 'B');
      expect(plan.segments[0].materialFor(3).name, 'A');
      expect(plan.segments[1].materialFor(3).name, 'B');
    });

    test('预览版默认是第一个选中的', () {
      final seg = BgmPlan.empty
          .assign(
              startUnit: 0, endUnit: 0, materials: [_b, _a], rangeMs: 5000)
          .segments
          .single;

      expect(seg.previewMaterial.name, 'B');
    });

    test('可以指定别的当预览版', () {
      final seg = BgmPlan.empty
          .assign(
              startUnit: 0,
              endUnit: 0,
              materials: [_a, _b, _c],
              rangeMs: 5000,
              previewIndex: 2)
          .segments
          .single;

      expect(seg.previewMaterial.name, 'C');
    });

    test('预览版下标越界时夹回第一个，不炸', () {
      final seg = BgmPlan.empty
          .assign(
              startUnit: 0,
              endUnit: 0,
              materials: [_a],
              rangeMs: 5000,
              previewIndex: 9)
          .segments
          .single;

      expect(seg.previewMaterial.name, 'A');
    });

    test('一首都不选等于没铺这一段', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 0, endUnit: 0, materials: const [], rangeMs: 1);

      expect(plan.segments, isEmpty);
    });
  });

  group('合并的条件变成「备选列表相同」', () {
    test('两段选的是同一组曲子就合并', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, materials: [_a, _b], rangeMs: 1)
          .assign(startUnit: 2, endUnit: 2, materials: [_a, _b], rangeMs: 1);

      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.endUnit, 2);
    });

    test('备选不一样就不合并——两段各轮各的', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, materials: [_a, _b], rangeMs: 1)
          .assign(startUnit: 2, endUnit: 2, materials: [_a], rangeMs: 1);

      expect(plan.segments, hasLength(2));
    });

    test('顺序不同也算不一样——轮流的次序是有意义的', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, materials: [_a, _b], rangeMs: 1)
          .assign(startUnit: 2, endUnit: 2, materials: [_b, _a], rangeMs: 1);

      expect(plan.segments, hasLength(2));
    });
  });

  group('老存档：一段只存了一首曲子', () {
    test('读成只有一个备选的段', () {
      final plan = BgmPlan.fromJson([
        {
          'startUnit': 0,
          'endUnit': 1,
          'material': _a.toJson(),
          'fit': BgmFit.loop.name,
          'volume': 0.4,
        }
      ]);

      expect(plan.segments.single.materials.map((m) => m.name), ['A']);
      expect(plan.segments.single.volume, 0.4);
    });

    test('存了再读回来备选与预览版都在', () {
      final plan = BgmPlan.empty.assign(
          startUnit: 0,
          endUnit: 1,
          materials: [_a, _b, _c],
          rangeMs: 1,
          previewIndex: 1);

      final back = BgmPlan.fromJson(plan.toJson());

      expect(back.segments.single.materials.map((m) => m.id), [1, 2, 3]);
      expect(back.segments.single.previewMaterial.name, 'B');
    });
  });
}
