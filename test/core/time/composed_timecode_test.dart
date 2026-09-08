import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/time/timecode.dart';

/// **界面上的时间数字一律成片时间，而且每次现算。**
///
/// 2026-09-08 讨论，用户原话：「那每一次实际上它的时间都是不一致的……
/// 那么就把这个改成帧数吧，然后每次重新计算。」
///
/// 症结不是单位（属性栏本来就是 分:秒.帧），是**基准**：左栏和属性栏给的是
/// 原片时间，时间线和播放器给的是成片时间。同一镜属性栏写 00:45.03、
/// 时间线画在 01:03——两个数谁也对不上谁。
///
/// 存的永远是原片毫秒（那是切分点，是数据本身）；成片时间是**派生量**，
/// 显示时现算。存成片时间的话，加一个单元就要重写每一个单元再落盘，
/// 写一半崩了就烂在盘上。
void main() {
  /// U1 手加（原片里没有它，占位排在原片末尾）；U2/U3 来自原片
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
            endMs: 8000,
            transcript: '第一句',
            shots: [
              Shot(startMs: 0, endMs: 3000),
              Shot(startMs: 3000, endMs: 8000),
            ]),
        SemanticUnit(
            index: 2,
            startMs: 8000,
            endMs: 20000,
            transcript: '第二句',
            shots: [Shot(startMs: 8000, endMs: 20000)]),
      ];

  ComposedTimeline line({Map<int, int> whole = const {}}) =>
      ComposedTimeline.of(units: units(), wholeDurations: whole);

  group('单元的成片位置', () {
    test('列表顺序就是成片顺序——手加的排在最前，它就从 0 开始', () {
      final t = line();

      expect(t.startOf(0), 0);
      expect(t.startOf(1), 10000, reason: 'U1 占了 10s，原片那一段整体后挪');
      expect(t.startOf(2), 18000);
    });

    test('整体替换：这一段的长度跟素材走，后面全跟着挪', () {
      final t = line(whole: {1: 5000});

      expect(t.startOf(1), 10000);
      expect(t.durationOf(1), 5000);
      expect(t.startOf(2), 15000, reason: '前面短了 3s，后面就早 3s');
    });
  });

  group('镜头的成片位置', () {
    test('镜头在成片里的起止 = 单元起点 + 它在单元里的偏移', () {
      final t = line();

      expect(t.composedShotStart(2, 0), 18000);
      expect(t.composedShotEnd(2, 0), 30000);
      expect(t.composedShotStart(1, 1), 13000);
      expect(t.composedShotEnd(1, 1), 18000);
    });

    test('整体替换的单元：镜头在成片里根本不存在，给 null 而不是编一个数', () {
      final t = line(whole: {1: 5000});

      expect(t.composedShotStart(1, 0), isNull,
          reason: '整段换成了另一条素材，原片的镜头切分在成片里已经没有了——'
              '按比例缩一个数出来是假精度，人会拿它去对时');
      expect(t.composedShotEnd(1, 0), isNull);
    });

    test('越界不抛——界面在编辑过程中会短暂拿到对不上的下标', () {
      final t = line();

      expect(t.composedShotStart(99, 0), isNull);
      expect(t.composedShotStart(1, 99), isNull);
    });
  });

  group('时间码：分:秒.帧', () {
    test('帧位就是帧位，不是百分之一秒', () {
      expect(formatTimecode(45100, 30), '00:45.03');
    });

    test('满一秒进位', () {
      expect(formatTimecode(1000, 30), '00:01.00');
      expect(formatTimecode(966, 30), '00:00.29');
      expect(formatTimecode(1966, 30), '00:01.29');
    });

    test('过一分钟', () {
      expect(formatTimecode(96233, 30), '01:36.07');
    });
  });

  group('整帧对齐', () {
    test('手加单元的时长按整帧对齐——不对齐的话一路累加会漂', () {
      expect(alignToFrame(10000, 30), 10000);
      expect(alignToFrame(10010, 30), 10000);
      expect(alignToFrame(10020, 30), 10033);
    });

    test('对齐过的再对齐还是它自己', () {
      final once = alignToFrame(15017, 30);

      expect(alignToFrame(once, 30), once);
    });

    test('fps 不合法时原样返回，不去除以 0', () {
      expect(alignToFrame(1234, 0), 1234);
    });
  });
}
