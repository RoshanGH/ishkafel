import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';

const _a = BgmMaterial(
    id: 1, name: '尤克里里', durationMs: 30000, previewUrl: 'https://o/a.mp3');
const _b = BgmMaterial(
    id: 2, name: '风声', durationMs: 30000, previewUrl: 'https://o/b.mp3');

BgmPlan _plan(List<(int, int, BgmMaterial, double)> segs) {
  var plan = BgmPlan.empty;
  for (final (from, to, m, v) in segs) {
    plan = plan.assign(
        startUnit: from,
        endUnit: to,
        material: m,
        rangeMs: 5000,
        volume: v);
  }
  return plan;
}

void main() {
  group('相邻的同一首曲子合并——不在接缝处从头重播', () {
    test('挨着的两段同素材并成一段', () {
      final plan = _plan([(0, 5, _a, 0.25), (6, 10, _a, 0.25)]);

      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.startUnit, 0);
      expect(plan.segments.single.endUnit, 10);
    });

    test('音量不同也合并，用最后设的那个——你刚调的那次应该赢', () {
      final plan = _plan([(0, 5, _a, 0.25), (6, 10, _a, 0.4)]);

      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.volume, 0.4,
          reason: '选这一段时顺手设了音量，合并后被前一段盖掉'
              '会让人觉得「我刚设的没生效」');
    });

    test('反过来也一样：后设的 25% 盖掉先前的 40%', () {
      final plan = _plan([(0, 5, _a, 0.4), (6, 10, _a, 0.25)]);

      expect(plan.segments.single.volume, 0.25);
    });

    test('不同曲子挨着不合并', () {
      final plan = _plan([(0, 5, _a, 0.25), (6, 10, _b, 0.25)]);

      expect(plan.segments, hasLength(2));
    });

    test('中间隔着镜头就不算相邻', () {
      final plan = _plan([(0, 5, _a, 0.25), (7, 10, _a, 0.25)]);

      expect(plan.segments, hasLength(2), reason: 'S6 没有配乐，中间是断的');
    });

    test('三段连着的同素材一次并成一段', () {
      final plan = _plan([
        (0, 2, _a, 0.25),
        (3, 5, _a, 0.25),
        (6, 8, _a, 0.25),
      ]);

      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.endUnit, 8);
    });

    test('新段落插在两段同素材中间时，三段并成一段', () {
      final plan = _plan([
        (0, 2, _a, 0.25),
        (6, 8, _a, 0.25),
        (3, 5, _a, 0.25),
      ]);

      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.startUnit, 0);
      expect(plan.segments.single.endUnit, 8);
    });

    test('合并改了另一段的音量时要说得出来——不能静默改掉用户设过的值', () {
      final before = _plan([(0, 5, _a, 0.25)]);
      final after = before.assign(
          startUnit: 6,
          endUnit: 10,
          material: _a,
          rangeMs: 5000,
          volume: 0.4);

      expect(after.mergedVolumeNotice, contains('40%'));
      expect(before.mergedVolumeNotice, isNull, reason: '没发生合并就没有这句话');
    });

    test('音量本来就一样时不必多嘴', () {
      final plan = _plan([(0, 5, _a, 0.25), (6, 10, _a, 0.25)]);

      expect(plan.mergedVolumeNotice, isNull);
    });
  });

  group('整体替换掉一个单元，就把它盖住的那段配乐抠掉', () {
    test('被替换的单元在前面：截断', () {
      final plan = _plan([(0, 12, _a, 0.25)]).carveOutUnits(0, 5);

      expect(plan.segments.single.startUnit, 6);
      expect(plan.segments.single.endUnit, 12);
    });

    test('被替换的单元在后面：截断', () {
      final plan = _plan([(0, 12, _a, 0.25)]).carveOutUnits(6, 12);

      expect(plan.segments.single.startUnit, 0);
      expect(plan.segments.single.endUnit, 5);
    });

    test('被替换的单元在中间：劈成两段，各自从头播', () {
      final plan = _plan([(0, 12, _a, 0.25)]).carveOutUnits(6, 8);

      expect(plan.segments, hasLength(2));
      expect(plan.segments[0].endUnit, 5);
      expect(plan.segments[1].startUnit, 9);
    });

    test('被替换的单元整个包住这段配乐：整段消失', () {
      final plan = _plan([(3, 5, _a, 0.25)]).carveOutUnits(0, 10);

      expect(plan.segments, isEmpty);
    });

    test('不相干的段落原样保留', () {
      final plan =
          _plan([(0, 2, _a, 0.25), (8, 10, _b, 0.4)]).carveOutUnits(4, 6);

      expect(plan.segments, hasLength(2));
      expect(plan.segments[1].volume, 0.4);
    });

    test('劈开之后两半各留各的音量', () {
      final plan = _plan([(0, 12, _a, 0.4)]).carveOutUnits(6, 8);

      expect(plan.segments.every((s) => s.volume == 0.4), isTrue);
    });

    test('抠完之后如果两段又挨上了，仍然合并', () {
      // S6 单独一段 A，两边也是 A；把 S6 抠掉再补回来的情形
      final plan = _plan([(0, 5, _a, 0.25), (7, 10, _a, 0.25)])
          .assign(startUnit: 6, endUnit: 6, material: _a, rangeMs: 1000);

      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.startUnit, 0);
      expect(plan.segments.single.endUnit, 10);
    });

    test('没有配乐时抠不出问题', () {
      expect(BgmPlan.empty.carveOutUnits(0, 5).segments, isEmpty);
    });
  });
}
