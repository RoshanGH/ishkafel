import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';

/// 拖完顺序，时间线要跟着重画。
///
/// 真机 bug（2026-09-07）：加了一个单元、把它拖到第一位，左栏改了、时间线
/// 没动——那个块还画在拖动之前的位置。原因是时间轴只在**总时长变了**时才换，
/// 而调顺序恰恰不改变总时长。
///
/// 「列表顺序就是成片顺序」这句话，只有时间线也跟着才成立。
SemanticUnit _u(int index, int start, int end) => SemanticUnit(
      index: index,
      startMs: start,
      endMs: end,
      transcript: 'src$start',
    );

void main() {
  group('调顺序之后的成片时间轴', () {
    test('总时长不变，但每个单元的成片起点变了', () {
      final before = [_u(0, 0, 1000), _u(1, 1000, 3000), _u(2, 3000, 4000)];
      // 把第三个拖到最前面
      final after = [_u(0, 3000, 4000), _u(1, 0, 1000), _u(2, 1000, 3000)];

      final a = ComposedTimeline.of(units: before, wholeDurations: const {});
      final b = ComposedTimeline.of(units: after, wholeDurations: const {});

      expect(a.totalMs, b.totalMs,
          reason: '前提：调顺序不改变总时长——所以「总时长变了才换轴」必然漏掉它');
      expect(a.startOf(0), 0);
      expect(b.startOf(1), 1000,
          reason: '拖完之后，原来的第一个排到了第二位，成片起点从 0 变成 1000');
    });

    test('同一份顺序：布局相同', () {
      final units = [_u(0, 0, 1000), _u(1, 1000, 3000)];
      final a = ComposedTimeline.of(units: units, wholeDurations: const {});
      final b = ComposedTimeline.of(units: units, wholeDurations: const {});

      expect(a.sameLayoutAs(b), isTrue);
    });

    test('顺序变了：布局不同——界面靠它判断要不要换轴', () {
      final a = ComposedTimeline.of(
          units: [_u(0, 0, 1000), _u(1, 1000, 3000), _u(2, 3000, 4000)],
          wholeDurations: const {});
      final b = ComposedTimeline.of(
          units: [_u(0, 3000, 4000), _u(1, 0, 1000), _u(2, 1000, 3000)],
          wholeDurations: const {});

      expect(a.sameLayoutAs(b), isFalse,
          reason: '总时长一样，但每一格的起点和取自原片的哪一段都变了');
    });

    test('单元数变了当然也算不同', () {
      final a = ComposedTimeline.of(
          units: [_u(0, 0, 1000)], wholeDurations: const {});
      final b = ComposedTimeline.of(
          units: [_u(0, 0, 1000), _u(1, 1000, 2000)],
          wholeDurations: const {});

      expect(a.sameLayoutAs(b), isFalse);
    });

    test('整体替换改了某一格的长度也算不同', () {
      final units = [_u(0, 0, 1000), _u(1, 1000, 3000)];
      final a = ComposedTimeline.of(units: units, wholeDurations: const {});
      final b =
          ComposedTimeline.of(units: units, wholeDurations: const {1: 5000});

      expect(a.sameLayoutAs(b), isFalse);
    });
  });
}
