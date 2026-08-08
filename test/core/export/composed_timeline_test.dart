import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// 三个单元：0~4000、4000~10000、10000~14000
List<SemanticUnit> _units() => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [Shot(startMs: 0, endMs: 4000)],
      ),
      SemanticUnit(
        index: 1,
        startMs: 4000,
        endMs: 10000,
        transcript: 'U2',
        shots: [Shot(startMs: 4000, endMs: 10000)],
      ),
      SemanticUnit(
        index: 2,
        startMs: 10000,
        endMs: 14000,
        transcript: 'U3',
        shots: [Shot(startMs: 10000, endMs: 14000)],
      ),
    ];

void main() {
  _composedAxis();
  group('没有整体替换时，成片时间轴就是原片时间轴', () {
    test('每个单元的位置和时长都不变', () {
      final t = ComposedTimeline.of(units: _units(), wholeDurations: const {});

      expect(t.startOf(0), 0);
      expect(t.startOf(1), 4000);
      expect(t.startOf(2), 10000);
      expect(t.totalMs, 14000);
      expect(t.changed, isFalse);
    });
  });

  group('整体替换会改变时长，后面整体后移', () {
    test('U1 从 4.0 秒变成 5.2 秒，后面每个单元都后移 1.2 秒', () {
      final t = ComposedTimeline.of(
          units: _units(), wholeDurations: const {0: 5200});

      expect(t.durationOf(0), 5200);
      expect(t.startOf(0), 0);
      expect(t.startOf(1), 5200, reason: '原来是 4000');
      expect(t.startOf(2), 11200, reason: '原来是 10000');
      expect(t.totalMs, 15200);
      expect(t.changed, isTrue);
    });

    test('变短也一样，后面整体前移', () {
      final t = ComposedTimeline.of(
          units: _units(), wholeDurations: const {1: 3000});

      expect(t.startOf(2), 7000, reason: 'U2 从 6 秒缩到 3 秒');
      expect(t.totalMs, 11000);
    });

    test('多个单元同时被替换时逐个累加', () {
      final t = ComposedTimeline.of(
          units: _units(), wholeDurations: const {0: 5000, 2: 2000});

      expect(t.startOf(1), 5000);
      expect(t.startOf(2), 11000);
      expect(t.totalMs, 13000);
    });

    test('没被替换的单元保持原时长', () {
      final t = ComposedTimeline.of(
          units: _units(), wholeDurations: const {0: 5200});

      expect(t.durationOf(1), 6000);
      expect(t.durationOf(2), 4000);
    });
  });

  group('配乐区间按成片时间轴换算', () {
    test('整体替换之后，配乐段的毫秒位置跟着挪', () {
      final t = ComposedTimeline.of(
          units: _units(), wholeDurations: const {0: 5200});

      // 配乐铺在 U2~U3 上
      expect(t.rangeOfUnits(1, 2), (5200, 15200));
    });

    test('没有整体替换时就是原片的毫秒', () {
      final t = ComposedTimeline.of(units: _units(), wholeDurations: const {});

      expect(t.rangeOfUnits(1, 2), (4000, 14000));
    });

    test('单元下标越界时夹住，不抛异常', () {
      final t = ComposedTimeline.of(units: _units(), wholeDurations: const {});

      expect(t.rangeOfUnits(-3, 99), (0, 14000));
    });

    test('没有单元时返回 null', () {
      final t =
          ComposedTimeline.of(units: const [], wholeDurations: const {});

      expect(t.rangeOfUnits(0, 0), isNull);
      expect(t.totalMs, 0);
    });
  });

  group('把成片时间映射回原片时间（播放头要用）', () {
    test('落在没被替换的单元里时按偏移换算', () {
      final t = ComposedTimeline.of(
          units: _units(), wholeDurations: const {0: 5200});

      // 成片 6000ms 落在 U2（成片 5200~11200），进入 800ms
      expect(t.toSourceMs(6000), 4800, reason: 'U2 原片起点 4000 + 800');
    });

    test('落在被替换的单元里时按比例映射——那一段的画面根本不是原片的', () {
      final t = ComposedTimeline.of(
          units: _units(), wholeDurations: const {0: 5200});

      // 成片 2600ms 是 U1 的一半
      expect(t.toSourceMs(2600), 2000, reason: 'U1 原片 4000 的一半');
    });

    test('超出片尾时夹到最后', () {
      final t = ComposedTimeline.of(units: _units(), wholeDurations: const {});

      expect(t.toSourceMs(999999), 14000);
      expect(t.toSourceMs(-100), 0);
    });
  });
}

/// 时间线改成成片时间轴之后新增的换算
void _composedAxis() {
  group('原片刻度 → 成片刻度', () {
    /// U1 = 0~4000、U2 = 4000~10000；U1 被换成一条 2 秒的候选
    List<SemanticUnit> units() => const [
          SemanticUnit(
              index: 0, startMs: 0, endMs: 4000, transcript: 'U1', shots: []),
          SemanticUnit(
              index: 1, startMs: 4000, endMs: 10000, transcript: 'U2', shots: []),
        ];

    ComposedTimeline shortened() =>
        ComposedTimeline.of(units: units(), wholeDurations: const {0: 2000});

    test('被替换的那一格按新长度画，后面整体左移', () {
      final axis = shortened();

      expect(axis.toComposedMs(0), 0);
      expect(axis.toComposedMs(4000), 2000, reason: 'U1 只剩 2 秒');
      expect(axis.toComposedMs(10000), 8000, reason: 'U2 跟着前移 2 秒');
      expect(axis.totalMs, 8000);
    });

    test('格子内部按比例——用户拖到一半就是一半', () {
      expect(shortened().toComposedMs(2000), 1000);
    });

    test('没被替换的单元一一对应', () {
      expect(shortened().toComposedMs(7000), 5000,
          reason: 'U2 内部不缩放：4000→2000 之后再走 3000');
    });

    test('与反向换算互为逆运算（没被替换的段落上严格可逆）', () {
      final axis = shortened();

      for (final ms in [4000, 5000, 7000, 9999]) {
        expect(axis.toSourceMs(axis.toComposedMs(ms)), ms);
      }
    });

    test('越界不炸，夹到两端', () {
      final axis = shortened();

      expect(axis.toComposedMs(-100), 0);
      expect(axis.toComposedMs(999999), 8000);
    });

    test('认得出哪个单元被整体替换了', () {
      final axis = shortened();

      expect(axis.isReplaced(0), isTrue);
      expect(axis.isReplaced(1), isFalse);
      expect(axis.isReplaced(99), isFalse, reason: '越界不炸');
    });

    test('候选和原单元一样长时不算「被替换」——画法不用变', () {
      final axis =
          ComposedTimeline.of(units: units(), wholeDurations: const {0: 4000});

      expect(axis.isReplaced(0), isFalse);
      expect(axis.changed, isFalse);
    });
  });
}
