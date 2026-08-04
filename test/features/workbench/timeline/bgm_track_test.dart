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
    test('跨单元的连续区间时长是各镜头之和', () {
      final ms = shotRangeMs(_units(), from: 2, to: 3);

      expect(ms, 4000, reason: 'S3(4000-6000) + S4(6000-8000)');
    });

    test('单个镜头', () {
      expect(shotRangeMs(_units(), from: 0, to: 0), 2000);
    });

    test('倒着传也认', () {
      expect(shotRangeMs(_units(), from: 3, to: 2), 4000);
    });

    test('越界下标被夹住，不抛异常', () {
      expect(shotRangeMs(_units(), from: -5, to: 99), 10000);
      expect(shotRangeMs(const [], from: 0, to: 3), 0);
    });
  });

  group('把方案摊成可绘制的段', () {
    test('每段带上它在时间轴上的起止', () {
      final plan = const BgmPlan([]).assign(
        startShot: 1,
        endShot: 3,
        material: const BgmMaterial(
            id: 1, name: '垫乐', durationMs: 6000, previewUrl: null),
        shotRangeMs: 6000,
      );

      final spans = bgmSpans(plan, _units());

      expect(spans, hasLength(1));
      expect(spans.single.startMs, 2000);
      expect(spans.single.endMs, 8000, reason: '从 S2 开头到 S4 结尾');
      expect(spans.single.segment.material.name, '垫乐');
    });

    test('方案里引用了已经不存在的镜头下标时跳过那一段', () {
      const plan = BgmPlan([
        BgmSegment(
          startShot: 10,
          endShot: 12,
          material: BgmMaterial(
              id: 1, name: '垫乐', durationMs: 1000, previewUrl: null),
          fit: BgmFit.loop,
        ),
      ]);

      expect(bgmSpans(plan, _units()), isEmpty,
          reason: '用户把镜头合并掉之后，旧方案会指向不存在的下标——'
              '画一段悬空的配乐比不画更让人困惑');
    });

    test('尾端越界的段被夹到最后一个镜头', () {
      const plan = BgmPlan([
        BgmSegment(
          startShot: 3,
          endShot: 99,
          material: BgmMaterial(
              id: 1, name: '垫乐', durationMs: 1000, previewUrl: null),
          fit: BgmFit.loop,
        ),
      ]);

      final spans = bgmSpans(plan, _units());

      expect(spans.single.endMs, 10000);
    });
  });
}

void _shotIndexAt() {
  group('某个时刻落在第几个镜头上', () {
    test('落在镜头内部', () {
      expect(shotIndexAtMs(_units(), 2500), 1);
      expect(shotIndexAtMs(_units(), 7000), 3);
    });

    test('边界属于后一个镜头（半开区间 [start, end)）', () {
      expect(shotIndexAtMs(_units(), 2000), 1);
      expect(shotIndexAtMs(_units(), 6000), 3);
    });

    test('滑出片头片尾时夹住，不让选区突然消失', () {
      expect(shotIndexAtMs(_units(), -500), 0);
      expect(shotIndexAtMs(_units(), 999999), 4);
    });

    test('没有镜头时返回 null', () {
      expect(shotIndexAtMs(const [], 100), isNull);
    });
  });
}
