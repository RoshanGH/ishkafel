import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

void main() {
  group('TimelineHitTester', () {
    late TimelineGeometry geometry;

    setUp(() {
      // 基础几何参数：1s = 1000ms，100ms/px
      geometry = TimelineGeometry(durationMs: 10000, msPerPx: 100.0, scrollPx: 0);
    });

    group('ruler track (y in [0, 20])', () {
      test('click on ruler → RulerHit with correct ms', () {
        // 点击刻度轨 x=50px 处，应转换为 50 * 100 = 5000ms
        final hit = TimelineHitTester.hitTest(
          const Offset(50, 10),
          [],
          geometry,
        );
        expect(hit, isA<RulerHit>());
        expect((hit as RulerHit).ms, equals(5000));
      });

      test('ruler y=0 (top edge) → RulerHit', () {
        final hit = TimelineHitTester.hitTest(const Offset(100, 0), [], geometry);
        expect(hit, isA<RulerHit>());
      });

      test('ruler y=19 (bottom edge) → RulerHit', () {
        final hit = TimelineHitTester.hitTest(const Offset(100, 19), [], geometry);
        expect(hit, isA<RulerHit>());
      });
    });

    group('unit track (y in [24, 68])', () {
      test('click on unit block → UnitBlockHit with correct index', () {
        final units = [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 2000,
            transcript: 'unit0',
          ),
        ];
        // unit 0: x in [0, 20] (0~2000ms)
        // 点击 x=10px (1000ms)，在 unit 内部，不靠近边界
        final hit = TimelineHitTester.hitTest(const Offset(10, 46), units, geometry);
        expect(hit, isA<UnitBlockHit>());
        expect((hit as UnitBlockHit).unitIndex, equals(0));
      });

      test('click near unit start boundary ±6px → UnitBoundaryHit', () {
        final units = [
          SemanticUnit(index: 0, startMs: 0, endMs: 2000, transcript: 'unit0'),
          SemanticUnit(index: 1, startMs: 2000, endMs: 4000, transcript: 'unit1'),
        ];
        // unit0: [0, 20]px，unit1: [20, 40]px
        // 在 x=20±6 范围内（边界处）
        final hitLeft = TimelineHitTester.hitTest(const Offset(18, 46), units, geometry);
        expect(hitLeft, isA<UnitBoundaryHit>());
        expect((hitLeft as UnitBoundaryHit).leftUnitIndex, equals(0));

        final hitRight = TimelineHitTester.hitTest(const Offset(22, 46), units, geometry);
        expect(hitRight, isA<UnitBoundaryHit>());
        expect((hitRight as UnitBoundaryHit).leftUnitIndex, equals(0));
      });

      test('unit track y outside [24, 68] → null', () {
        final units = [
          SemanticUnit(index: 0, startMs: 0, endMs: 2000, transcript: 'unit0'),
        ];
        final hitAbove = TimelineHitTester.hitTest(const Offset(10, 23), units, geometry);
        expect(hitAbove, isNull);

        final hitBelow = TimelineHitTester.hitTest(const Offset(10, 69), units, geometry);
        expect(hitBelow, isNull);
      });
    });

    group('shot track (y in [72, 98])', () {
      test('click on shot block within unit → ShotBlockHit', () {
        final units = [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 4000,
            transcript: 'unit0',
            shots: [
              Shot(startMs: 0, endMs: 2000),    // shot 0: [0, 20]px
              Shot(startMs: 2000, endMs: 4000), // shot 1: [20, 40]px
            ],
          ),
        ];
        // 点击 shot0 中间（不靠近边界）
        final hit = TimelineHitTester.hitTest(const Offset(10, 85), units, geometry);
        expect(hit, isA<ShotBlockHit>());
        expect((hit as ShotBlockHit).unitIndex, equals(0));
        expect(hit.shotIndex, equals(0));
      });

      test('shot boundary within unit → ShotBoundaryHit', () {
        final units = [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 4000,
            transcript: 'unit0',
            shots: [
              Shot(startMs: 0, endMs: 2000),
              Shot(startMs: 2000, endMs: 4000),
            ],
          ),
        ];
        // shot 边界在 x=20px
        final hit = TimelineHitTester.hitTest(const Offset(20, 85), units, geometry);
        expect(hit, isA<ShotBoundaryHit>());
        expect((hit as ShotBoundaryHit).unitIndex, equals(0));
        expect(hit.leftShotIndex, equals(0));
      });

      test('shot boundary at unit boundary → UnitBoundaryHit (priority)', () {
        final units = [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 2000,
            transcript: 'unit0',
            shots: [Shot(startMs: 0, endMs: 2000)],
          ),
          SemanticUnit(
            index: 1,
            startMs: 2000,
            endMs: 4000,
            transcript: 'unit1',
            shots: [Shot(startMs: 2000, endMs: 4000)],
          ),
        ];
        // unit 边界在 x=20px，shot 边界也在 x=20px
        // 应该返回 UnitBoundaryHit（单元边界属单元层）
        final hit = TimelineHitTester.hitTest(const Offset(20, 85), units, geometry);
        expect(hit, isA<UnitBoundaryHit>());
        expect((hit as UnitBoundaryHit).leftUnitIndex, equals(0));
      });

      test('shot track y outside [72, 98] → null', () {
        final units = [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 2000,
            transcript: 'unit0',
            shots: [Shot(startMs: 0, endMs: 2000)],
          ),
        ];
        final hitAbove = TimelineHitTester.hitTest(const Offset(10, 71), units, geometry);
        expect(hitAbove, isNull);

        final hitBelow = TimelineHitTester.hitTest(const Offset(10, 99), units, geometry);
        expect(hitBelow, isNull);
      });
    });

    group('hit priority', () {
      test('boundary tolerance ±6px takes priority over block', () {
        final units = [
          SemanticUnit(index: 0, startMs: 0, endMs: 2000, transcript: 'unit0'),
          SemanticUnit(index: 1, startMs: 2000, endMs: 4000, transcript: 'unit1'),
        ];
        // unit 边界在 x=20px，测试 ±6px 范围
        for (int x = 14; x <= 26; x++) {
          final hit = TimelineHitTester.hitTest(Offset(x.toDouble(), 46), units, geometry);
          expect(hit, isA<UnitBoundaryHit>(), reason: 'x=$x should hit boundary');
        }
      });

      test('outside boundary tolerance → block hit', () {
        final units = [
          SemanticUnit(index: 0, startMs: 0, endMs: 2000, transcript: 'unit0'),
          SemanticUnit(index: 1, startMs: 2000, endMs: 4000, transcript: 'unit1'),
        ];
        // unit 边界在 x=20px，x=7 应该在 unit0 块体内
        final hit = TimelineHitTester.hitTest(const Offset(7, 46), units, geometry);
        expect(hit, isA<UnitBlockHit>());
        expect((hit as UnitBlockHit).unitIndex, equals(0));
      });
    });

    group('edge cases', () {
      test('empty units list on unit track → null', () {
        final hit = TimelineHitTester.hitTest(const Offset(10, 46), [], geometry);
        expect(hit, isNull);
      });

      test('y outside all tracks → null', () {
        final units = [
          SemanticUnit(index: 0, startMs: 0, endMs: 2000, transcript: 'unit0'),
        ];
        final hit = TimelineHitTester.hitTest(const Offset(10, 200), units, geometry);
        expect(hit, isNull);
      });

      test('scroll offset affects x calculation', () {
        // scroll=100px: x=50px 实际对应 (50+100)*100 = 15000ms
        final scrolledGeometry = TimelineGeometry(
          durationMs: 20000,
          msPerPx: 100.0,
          scrollPx: 100,
        );
        final hit = TimelineHitTester.hitTest(
          const Offset(50, 10),
          [],
          scrolledGeometry,
        );
        expect(hit, isA<RulerHit>());
        expect((hit as RulerHit).ms, equals(15000));
      });
    });
  });
}
