import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';

BgmMaterial _m(int id, String name) =>
    BgmMaterial(id: id, name: name, durationMs: 30000, previewUrl: 'u$id');

final _a = _m(1, 'A');
final _b = _m(2, 'B');

BgmPlan _two() => BgmPlan.empty
    .assign(startUnit: 0, endUnit: 2, materials: [_a], rangeMs: 1)
    .assign(startUnit: 3, endUnit: 5, materials: [_b], rangeMs: 1);

void main() {
  group('拖段落边界改长度', () {
    test('把右边界往左拖：这一段缩短', () {
      final plan = _two().resize(startUnit: 0, newStart: 0, newEnd: 1);

      expect(plan.segments[0].endUnit, 1);
      expect(plan.segments[1].startUnit, 3, reason: '后面那段不动');
    });

    test('把左边界往右拖：这一段缩短，前面空出来', () {
      final plan = _two().resize(startUnit: 3, newStart: 4, newEnd: 5);

      expect(plan.segments[1].startUnit, 4);
      expect(plan.segments[0].endUnit, 2, reason: '前面那段不动');
    });

    test('右边界拖过头压到下一段时夹住——不许两段抢同一个单元', () {
      final plan = _two().resize(startUnit: 0, newStart: 0, newEnd: 9);

      expect(plan.segments[0].endUnit, 2,
          reason: '下一段从 U4 开始，最多只能到 U3');
      expect(plan.segments[1].startUnit, 3);
    });

    test('左边界拖过头压到上一段时同样夹住', () {
      final plan = _two().resize(startUnit: 3, newStart: 0, newEnd: 5);

      expect(plan.segments[1].startUnit, 3);
      expect(plan.segments[0].endUnit, 2);
    });

    test('拖到起点越过终点时不翻转，保持至少一个单元', () {
      final plan = _two().resize(startUnit: 0, newStart: 2, newEnd: 0);

      expect(plan.segments[0].startUnit, plan.segments[0].endUnit);
    });

    test('改完之后如果和相邻段落成了同一组备选，照样合并', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, materials: [_a], rangeMs: 1)
          .assign(startUnit: 3, endUnit: 4, materials: [_a], rangeMs: 1)
          .resize(startUnit: 3, newStart: 2, newEnd: 4);

      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.startUnit, 0);
      expect(plan.segments.single.endUnit, 4);
    });

    test('曲子、备选、音量、预览版都不变——改的只是长度', () {
      final before = BgmPlan.empty.assign(
          startUnit: 0,
          endUnit: 2,
          materials: [_a, _b],
          rangeMs: 1,
          previewIndex: 1,
          volume: 0.4);

      final after = before.resize(startUnit: 0, newStart: 0, newEnd: 1);

      expect(after.segments.single.materials.map((m) => m.id), [1, 2]);
      expect(after.segments.single.previewIndex, 1);
      expect(after.segments.single.volume, 0.4);
    });

    test('认不出这一段时原样返回，不炸', () {
      final plan = _two().resize(startUnit: 99, newStart: 0, newEnd: 1);

      expect(plan.segments, hasLength(2));
    });
  });

  group('删除一段', () {
    test('按起点删掉指定的那一段，其余不动', () {
      final plan = _two().removeSegment(3);

      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.startUnit, 0);
    });

    test('删掉之后剩下的相邻同组会合并', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, materials: [_a], rangeMs: 1)
          .assign(startUnit: 2, endUnit: 3, materials: [_b], rangeMs: 1)
          .assign(startUnit: 4, endUnit: 5, materials: [_a], rangeMs: 1)
          .removeSegment(2);

      expect(plan.segments, hasLength(2),
          reason: 'A 的两段中间隔着单元 2~3，删掉 B 之后仍然不相邻');
    });

    test('认不出这一段时原样返回', () {
      expect(_two().removeSegment(99).segments, hasLength(2));
    });
  });
}
