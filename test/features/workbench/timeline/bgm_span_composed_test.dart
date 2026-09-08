import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/features/workbench/timeline/bgm_track.dart';

/// **配乐段给的是成片区间，不是原片区间。**
///
/// 一期重构：`原片时刻 → 成片时刻` 这个方向是病态的（见
/// `docs/2026-09-08-成片时间轴重构-TRD.md` 二、2.2），要全部删掉。
/// 配乐本来就按**单元下标**记（startUnit..endUnit），成片区间按下标问轴就有，
/// 不必绕原片时间一圈——绕了就会在调序之后算到别的段上。
void main() {
  /// U1 手加（原片占位排末尾）被拖到最前；U2、U3 取自原片
  List<SemanticUnit> units() => const [
        SemanticUnit(
            index: 0,
            startMs: 20000,
            endMs: 30000,
            transcript: '',
            hasSource: false),
        SemanticUnit(index: 1, startMs: 0, endMs: 10000, transcript: '一'),
        SemanticUnit(index: 2, startMs: 10000, endMs: 20000, transcript: '二'),
      ];

  ComposedTimeline axis() =>
      ComposedTimeline.of(units: units(), wholeDurations: const {});

  BgmPlan planOf(int from, int to) => BgmPlan([
        BgmSegment(
            startUnit: from,
            endUnit: to,
            materials: const [],
            fit: BgmFit.loop)
      ]);

  test('盖住原片里最后一个单元：区间是它的成片位置，不是 0', () {
    final span = bgmSpans(planOf(2, 2), units(), axis()).single;

    expect(span.startMs, 20000);
    expect(span.endMs, 30000,
        reason: '按原片时间算的话，endMs=20000 落进手加单元的占位，'
            '被算成它的成片起点 0，配乐块左右翻转、整段画不出来');
  });

  test('盖住手加的那一段：从成片 0 开始', () {
    final span = bgmSpans(planOf(0, 0), units(), axis()).single;

    expect(span.startMs, 0);
    expect(span.endMs, 10000);
  });

  test('跨多个单元：从第一个的起点到最后一个的终点', () {
    final span = bgmSpans(planOf(0, 2), units(), axis()).single;

    expect(span.startMs, 0);
    expect(span.endMs, 30000);
  });

  test('起点指到不存在的单元就跳过——画一段悬空的配乐更让人困惑', () {
    expect(bgmSpans(planOf(9, 9), units(), axis()), isEmpty);
  });

  test('尾端越界夹到最后一个单元', () {
    final span = bgmSpans(planOf(1, 99), units(), axis()).single;

    expect(span.endMs, 30000);
  });
}
