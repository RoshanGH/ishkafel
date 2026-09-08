import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';

/// **命中判定也得按下标问成片轴。**
///
/// 2026-09-08 真机：「U6 不能正常播放」。根子不在播放——是那一格**根本点不中**：
/// 命中判定拿 `unit.endMs` 去换算成片位置，而 endMs 是开区间，落进的是相邻
/// 那一段。手加的单元被拖到最前之后（它在原片上的占位排在末尾），原片里最后
/// 那个单元的右边界被算成手加单元的成片起点 0，区间左右翻转，`x >= start &&
/// x < end` 永远不成立。点不中就选不中，选不中就双击不出播放。
///
/// 和绘制是同一个错误（timeline_painter 的 _unitPx/_shotPx）。
void main() {
  /// U1 手加（原片占位排末尾）被拖到最前；U2、U3 来自原片
  List<SemanticUnit> units() => const [
        SemanticUnit(
            index: 0,
            startMs: 20000,
            endMs: 30000,
            transcript: '',
            hasSource: false),
        SemanticUnit(
            index: 1,
            startMs: 0,
            endMs: 10000,
            transcript: '第一句',
            shots: [Shot(startMs: 0, endMs: 10000)]),
        SemanticUnit(
            index: 2,
            startMs: 10000,
            endMs: 20000,
            transcript: '第二句',
            shots: [
              Shot(startMs: 10000, endMs: 15000),
              Shot(startMs: 15000, endMs: 20000),
            ]),
      ];

  /// 成片 30s，1ms = 0.05px（即 20ms/px）：U3 在成片 20~30s → x 1000~1500
  TimelineGeometry geometry() => TimelineGeometry(
      durationMs: 30000,
      msPerPx: 20,
      scrollPx: 0,
      axis: ComposedTimeline.of(units: units(), wholeDurations: const {}));

  double unitsY() =>
      (TimelineTracks.unitsTop + TimelineTracks.unitsBottom) / 2;
  double shotsY() =>
      (TimelineTracks.shotsTop + TimelineTracks.shotsBottom) / 2;

  test('点最后一个单元的块体：选中它，而不是什么也选不中', () {
    final hit = TimelineHitTester.hitTest(
        Offset(1250, unitsY()), units(), geometry());

    expect(hit, isA<UnitBlockHit>(),
        reason: '真机上这里返回 null——点下去没反应，选中态停在上一格，'
            '于是双击也播不了（「U6 不能正常播放」）');
    expect((hit! as UnitBlockHit).unitIndex, 2);
  });

  test('点最后一镜：选中它', () {
    final hit = TimelineHitTester.hitTest(
        Offset(1400, shotsY()), units(), geometry());

    expect(hit, isA<ShotBlockHit>());
    expect((hit! as ShotBlockHit).unitIndex, 2);
    expect((hit as ShotBlockHit).shotIndex, 1);
  });

  test('前面几格照旧点得中', () {
    final u1 = TimelineHitTester.hitTest(
        Offset(200, unitsY()), units(), geometry());
    final u2 = TimelineHitTester.hitTest(
        Offset(700, unitsY()), units(), geometry());

    expect((u1! as UnitBlockHit).unitIndex, 0);
    expect((u2! as UnitBlockHit).unitIndex, 1);
  });
}
