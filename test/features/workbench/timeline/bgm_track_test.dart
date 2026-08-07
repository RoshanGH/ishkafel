import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/features/workbench/timeline/bgm_track.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// 两个单元共 5 个镜头，全片打平的镜头下标是 0..4
List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 6000,
        transcript: 'U1',
        shots: [
          Shot(startMs: 0, endMs: 2000),
          Shot(startMs: 2000, endMs: 4000),
          Shot(startMs: 4000, endMs: 6000),
        ],
      ),
      SemanticUnit(
        index: 1,
        startMs: 6000,
        endMs: 10000,
        transcript: 'U2',
        shots: [
          Shot(startMs: 6000, endMs: 8000),
          Shot(startMs: 8000, endMs: 10000),
        ],
      ),
    ];

void main() {
  _shotIndexAt();

  group('全片打平的镜头下标 ↔ 单元内位置', () {
    test('按顺序连续编号，跨单元不断档', () {
      final flat = flattenShots(_units());

      expect(flat, hasLength(5));
      expect(flat[2].unitIndex, 0);
      expect(flat[2].shotIndex, 2);
      expect(flat[3].unitIndex, 1, reason: '第 4 个镜头已经在第二个单元里了');
      expect(flat[3].shotIndex, 0);
    });

    test('带上各自的时间范围，供绘制与时长计算', () {
      final flat = flattenShots(_units());

      expect(flat.first.startMs, 0);
      expect(flat.last.endMs, 10000);
    });

    test('没有镜头时返回空，不崩', () {
      expect(flattenShots(const []), isEmpty);
    });
  });

  group('区间时长', () {
    test('连续几个单元的时长是它们之和', () {
      final ms = unitRangeMs(_units(), from: 0, to: 1);

      expect(ms, 10000, reason: 'U1(0-6000) + U2(6000-10000)');
    });

    test('单个单元', () {
      expect(unitRangeMs(_units(), from: 0, to: 0), 6000);
    });

    test('倒着传也认', () {
      expect(unitRangeMs(_units(), from: 1, to: 0), 10000);
    });

    test('越界下标被夹住，不抛异常', () {
      expect(unitRangeMs(_units(), from: -5, to: 99), 10000);
      expect(unitRangeMs(const [], from: 0, to: 3), 0);
    });
  });

  group('把方案摊成可绘制的段', () {
    test('每段带上它在时间轴上的起止', () {
      final plan = const BgmPlan([]).assign(
        startUnit: 1,
        endUnit: 1,
        materials: [const BgmMaterial(
            id: 1, name: '垫乐', durationMs: 6000, previewUrl: null)],
        rangeMs: 4000,
      );

      final spans = bgmSpans(plan, _units());

      expect(spans, hasLength(1));
      expect(spans.single.startMs, 6000);
      expect(spans.single.endMs, 10000, reason: 'U2 的起止');
      expect(spans.single.segment.previewMaterial.name, '垫乐');
    });

    test('方案里引用了已经不存在的单元下标时跳过那一段', () {
      const plan = BgmPlan([
        BgmSegment(
          startUnit: 10,
          endUnit: 12,
          materials: [BgmMaterial(
              id: 1, name: '垫乐', durationMs: 1000, previewUrl: null)],
          fit: BgmFit.loop,
        ),
      ]);

      expect(bgmSpans(plan, _units()), isEmpty,
          reason: '用户把单元合并掉之后，旧方案会指向不存在的下标——'
              '画一段悬空的配乐比不画更让人困惑');
    });

    test('尾端越界的段被夹到最后一个单元', () {
      const plan = BgmPlan([
        BgmSegment(
          startUnit: 1,
          endUnit: 99,
          materials: [BgmMaterial(
              id: 1, name: '垫乐', durationMs: 1000, previewUrl: null)],
          fit: BgmFit.loop,
        ),
      ]);

      final spans = bgmSpans(plan, _units());

      expect(spans.single.endMs, 10000);
    });
  });
}

void _shotIndexAt() {
  // 配乐轨按台词语义单元对齐（U1 0~6000、U2 6000~10000），
  // 框选时吸附到单元边界而不是 51 个镜头一格一格对
  group('某个时刻落在第几个台词语义单元上', () {
    test('落在单元内部', () {
      expect(unitIndexAtMs(_units(), 2500), 0);
      expect(unitIndexAtMs(_units(), 7000), 1);
    });

    test('边界属于后一个单元（半开区间 [start, end)）', () {
      expect(unitIndexAtMs(_units(), 6000), 1);
      expect(unitIndexAtMs(_units(), 5999), 0);
    });

    test('滑出片头片尾时夹住，不让选区突然消失', () {
      expect(unitIndexAtMs(_units(), -500), 0);
      expect(unitIndexAtMs(_units(), 999999), 1);
    });

    test('没有单元时返回 null', () {
      expect(unitIndexAtMs(const [], 100), isNull);
    });
  });
}
