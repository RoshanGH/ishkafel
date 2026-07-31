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

    group('窄块体的边界手柄不得互相遮挡（Critical 4）', () {
      // fit 缩放下 96 秒片长里 1.2 秒的镜头只有约 1.2px 宽，很常见。固定 ±6px
      // 容差会让相邻两条边界的容差区把整个块体盖住：块体本身永远命中不到，
      // 用户既选不中这个镜头、也无从调它的右边界，只能靠放大缩放绕开。
      const shotY = 85.0;
      const unitY = 46.0;
      const msPerPx = 100.0;

      /// 三个等宽块体（每个 [widthPx] 像素）的几何 + ms 跨度
      (TimelineGeometry, int) tripleOf(double widthPx) => (
            const TimelineGeometry(
                durationMs: 100000, msPerPx: msPerPx, scrollPx: 0),
            (widthPx * msPerPx).round(),
          );

      for (final widthPx in [4.0, 8.0, 12.0, 40.0]) {
        test('镜头轨块宽 ${widthPx}px：左边界 / 块体 / 右边界都能命中', () {
          final (geo, span) = tripleOf(widthPx);
          final units = [
            SemanticUnit(
              index: 0,
              startMs: 0,
              endMs: span * 3,
              transcript: 'u0',
              shots: [
                Shot(startMs: 0, endMs: span),
                Shot(startMs: span, endMs: span * 2),
                Shot(startMs: span * 2, endMs: span * 3),
              ],
            ),
          ];

          // 块心必须命中块体本身（否则该镜头在时间线上根本选不中）
          final centerHit =
              TimelineHitTester.hitTest(Offset(widthPx * 1.5, shotY), units, geo);
          expect(centerHit, const ShotBlockHit(unitIndex: 0, shotIndex: 1),
              reason: '块宽 $widthPx 的镜头块心应命中块体');

          // 左边界
          final leftHit =
              TimelineHitTester.hitTest(Offset(widthPx, shotY), units, geo);
          expect(leftHit, const ShotBoundaryHit(unitIndex: 0, leftShotIndex: 0));

          // 右边界
          final rightHit =
              TimelineHitTester.hitTest(Offset(widthPx * 2, shotY), units, geo);
          expect(rightHit, const ShotBoundaryHit(unitIndex: 0, leftShotIndex: 1));
        });

        test('单元轨块宽 ${widthPx}px：左边界 / 块体 / 右边界都能命中', () {
          final (geo, span) = tripleOf(widthPx);
          final units = [
            for (var i = 0; i < 3; i++)
              SemanticUnit(
                index: i,
                startMs: span * i,
                endMs: span * (i + 1),
                transcript: 'u$i',
                shots: [Shot(startMs: span * i, endMs: span * (i + 1))],
              ),
          ];

          expect(
              TimelineHitTester.hitTest(Offset(widthPx * 1.5, unitY), units, geo),
              const UnitBlockHit(unitIndex: 1),
              reason: '块宽 $widthPx 的单元块心应命中块体');
          expect(TimelineHitTester.hitTest(Offset(widthPx, unitY), units, geo),
              const UnitBoundaryHit(leftUnitIndex: 0));
          expect(
              TimelineHitTester.hitTest(Offset(widthPx * 2, unitY), units, geo),
              const UnitBoundaryHit(leftUnitIndex: 1));
        });
      }

      test('容差取「±6px」与「较窄一侧块宽的三分之一」中的较小者', () {
        expect(TimelineHitTester.boundaryToleranceFor(40, 40), 6.0);
        expect(TimelineHitTester.boundaryToleranceFor(12, 12), closeTo(4.0, 1e-9));
        expect(TimelineHitTester.boundaryToleranceFor(40, 9), closeTo(3.0, 1e-9),
            reason: '取较窄的一侧');
        expect(TimelineHitTester.boundaryToleranceFor(9, 40), closeTo(3.0, 1e-9));
      });

      test('块体窄到容差不足 1px 时放弃边界命中，优先保证块体可选中', () {
        expect(TimelineHitTester.boundaryToleranceFor(2, 40), 0.0);

        final geo = const TimelineGeometry(
            durationMs: 100000, msPerPx: 100.0, scrollPx: 0);
        // 中间镜头只有 2px 宽（200ms）
        final units = [
          const SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 4200,
            transcript: 'u0',
            shots: [
              Shot(startMs: 0, endMs: 2000),
              Shot(startMs: 2000, endMs: 2200),
              Shot(startMs: 2200, endMs: 4200),
            ],
          ),
        ];
        // 该镜头占 [20,22]px，两端边界都不再抢命中，块体整段可选中
        for (final x in [20.0, 21.0, 21.9]) {
          expect(TimelineHitTester.hitTest(Offset(x, shotY), units, geo),
              const ShotBlockHit(unitIndex: 0, shotIndex: 1),
              reason: 'x=$x');
        }
      });

      test('单元交界处的边界仍归单元层（容差自适应后不改变这一优先级）', () {
        final geo = const TimelineGeometry(
            durationMs: 100000, msPerPx: 100.0, scrollPx: 0);
        // 两个单元各一个 12px 宽的镜头，交界在 x=12
        final units = [
          const SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 1200,
            transcript: 'u0',
            shots: [Shot(startMs: 0, endMs: 1200)],
          ),
          const SemanticUnit(
            index: 1,
            startMs: 1200,
            endMs: 2400,
            transcript: 'u1',
            shots: [Shot(startMs: 1200, endMs: 2400)],
          ),
        ];
        expect(TimelineHitTester.hitTest(const Offset(12, shotY), units, geo),
            const UnitBoundaryHit(leftUnitIndex: 0));
        // 块心仍可选中镜头
        expect(TimelineHitTester.hitTest(const Offset(6, shotY), units, geo),
            const ShotBlockHit(unitIndex: 0, shotIndex: 0));
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
