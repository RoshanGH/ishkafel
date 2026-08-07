import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

const _a = BgmMaterial(
    id: 1, name: '尤克里里', durationMs: 30000, previewUrl: 'https://o/a.mp3');

/// 三个单元，各 2 / 3 / 2 个镜头
List<SemanticUnit> _units() => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [
          Shot(startMs: 0, endMs: 2000),
          Shot(startMs: 2000, endMs: 4000),
        ],
      ),
      SemanticUnit(
        index: 1,
        startMs: 4000,
        endMs: 10000,
        transcript: 'U2',
        shots: [
          Shot(startMs: 4000, endMs: 6000),
          Shot(startMs: 6000, endMs: 8000),
          Shot(startMs: 8000, endMs: 10000),
        ],
      ),
      SemanticUnit(
        index: 2,
        startMs: 10000,
        endMs: 14000,
        transcript: 'U3',
        shots: [
          Shot(startMs: 10000, endMs: 12000),
          Shot(startMs: 12000, endMs: 14000),
        ],
      ),
    ];

void main() {
  group('配乐按台词语义单元对齐，不再按镜头', () {
    test('铺在 U1~U2 上', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, material: _a, rangeMs: 10000);

      expect(plan.segments.single.startUnit, 0);
      expect(plan.segments.single.endUnit, 1);
    });

    test('换算成毫秒时直接取单元的起止——镜头在整体替换后就不存在了', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 1, endUnit: 2, material: _a, rangeMs: 10000);

      expect(BgmPlan.unitRangeOf(_units(), plan.segments.single), (4000, 14000));
    });

    test('单元下标越界时返回 null，不炸', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 9, endUnit: 9, material: _a, rangeMs: 1000);

      expect(BgmPlan.unitRangeOf(_units(), plan.segments.single), isNull);
    });

    test('整体替换掉 U2：配乐劈成 U1 和 U3', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 0, endUnit: 2, material: _a, rangeMs: 14000)
          .carveOutUnits(1, 1);

      expect(plan.segments, hasLength(2));
      expect(plan.segments[0].endUnit, 0);
      expect(plan.segments[1].startUnit, 2);
    });

    test('把 U2 的配乐重新选回同一首时，三段并成一段', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 0, endUnit: 2, material: _a, rangeMs: 14000)
          .carveOutUnits(1, 1)
          .assign(startUnit: 1, endUnit: 1, material: _a, rangeMs: 6000);

      expect(plan.segments, hasLength(1),
          reason: '用户描述的流程：抠掉之后重选同一首，接得上就合并');
      expect(plan.segments.single.startUnit, 0);
      expect(plan.segments.single.endUnit, 2);
    });
  });

  group('老存档要迁移过来——不能让用户已经选好的配乐凭空消失', () {
    test('按镜头存的区间换算成单元区间', () {
      // 老格式：S0~S4（跨 U1 的 2 个镜头 + U2 的前 3 个）
      final plan = BgmPlan.fromJson([
        {
          'startShot': 0,
          'endShot': 4,
          'material': _a.toJson(),
          'fit': BgmFit.loop.name,
          'volume': 0.4,
        }
      ]).migrateShotsToUnits(_units());

      expect(plan.segments.single.startUnit, 0);
      expect(plan.segments.single.endUnit, 1,
          reason: '跨到哪个单元就算到哪个单元——粒度变粗是这次改动的代价');
      expect(plan.segments.single.volume, 0.4, reason: '音量要留住');
    });

    test('已经是单元格式的不再动它', () {
      final plan = BgmPlan.empty
          .assign(startUnit: 1, endUnit: 2, material: _a, rangeMs: 10000);

      final again = plan.migrateShotsToUnits(_units());

      expect(again.segments.single.startUnit, 1);
      expect(again.segments.single.endUnit, 2);
    });

    test('镜头下标越界的老数据丢掉，不留一段指向不存在单元的配乐', () {
      final plan = BgmPlan.fromJson([
        {
          'startShot': 99,
          'endShot': 120,
          'material': _a.toJson(),
          'fit': BgmFit.loop.name,
        }
      ]).migrateShotsToUnits(_units());

      expect(plan.segments, isEmpty);
    });

    test('迁移后相邻同素材照样合并', () {
      final plan = BgmPlan.fromJson([
        {'startShot': 0, 'endShot': 1, 'material': _a.toJson(), 'fit': 'exact'},
        {'startShot': 2, 'endShot': 4, 'material': _a.toJson(), 'fit': 'exact'},
      ]).migrateShotsToUnits(_units());

      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.startUnit, 0);
      expect(plan.segments.single.endUnit, 1);
    });
  });
}
