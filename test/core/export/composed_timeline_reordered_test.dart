import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';

/// 单元被拖乱顺序之后：**列表顺序是成片顺序，startMs 只说明它取自原片哪一段**。
/// 这两件事一旦分开，任何「按列表顺序扫、拿原片时间比大小」的写法都会错。
SemanticUnit _u(int index, int sourceStart, int sourceEnd) => SemanticUnit(
      index: index,
      startMs: sourceStart,
      endMs: sourceEnd,
      transcript: 'src$sourceStart',
    );

void main() {
  // 原片顺序是 A(0~1000) B(1000~3000) C(3000~4000)，
  // 用户把 C 拖到最前面 → 成片顺序 C A B
  List<SemanticUnit> reordered() => [
        _u(0, 3000, 4000),
        _u(1, 0, 1000),
        _u(2, 1000, 3000),
      ];

  ComposedTimeline axis() =>
      ComposedTimeline.of(units: reordered(), wholeDurations: const {});

  group('顺序被打乱后的成片时间轴', () {
    test('成片起点按列表顺序排，跟原片时间无关', () {
      final t = axis();

      expect(t.startOf(0), 0, reason: 'C 排第一，成片从 0 开始');
      expect(t.durationOf(0), 1000);
      expect(t.startOf(1), 1000, reason: 'A 接在 C 后面');
      expect(t.startOf(2), 2000, reason: 'B 再接在 A 后面');
      expect(t.totalMs, 4000);
    });

    test('成片某一刻落在第几个单元——按成片位置查，不看原片时间', () {
      final t = axis();

      expect(t.unitIndexAtComposedMs(0), 0);
      expect(t.unitIndexAtComposedMs(999), 0);
      expect(t.unitIndexAtComposedMs(1000), 1);
      expect(t.unitIndexAtComposedMs(2500), 2);
    });

    test('落在片头之前 / 片尾之后都夹到两端，不返回 null', () {
      final t = axis();
      expect(t.unitIndexAtComposedMs(-500), 0);
      expect(t.unitIndexAtComposedMs(99999), 2);
    });

    test('原片的某一刻画在成片的哪儿——按「谁的原片区间盖住它」找', () {
      final t = axis();

      // 原片 3500 属于 C，而 C 在成片里排第一（0~1000）
      expect(t.toComposedMs(3500), 500,
          reason: '顺序扫一遍比大小的话，会先撞上排在前面但原片更靠后的单元');
      // 原片 500 属于 A，A 在成片里 1000~2000
      expect(t.toComposedMs(500), 1500);
    });

    test('成片某一刻回推原片时刻', () {
      final t = axis();

      expect(t.toSourceMs(500), 3500, reason: '成片 500 在 C 里，对应原片 3500');
      expect(t.toSourceMs(1500), 500, reason: '成片 1500 在 A 里，对应原片 500');
    });
  });
}
