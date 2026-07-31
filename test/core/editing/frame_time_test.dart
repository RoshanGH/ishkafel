import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/frame_time.dart';

void main() {
  group('帧点换算', () {
    test('30fps 的帧点在毫秒轴上非等距（33/34 交替）', () {
      expect([for (var i = 0; i < 5; i++) msOfFrame(i, 30)],
          [0, 33, 67, 100, 133],
          reason: '正因为非等距，「往前一帧」不能在毫秒上加减常数');
    });

    test('毫秒 → 帧序号 → 毫秒 在帧点上可往返', () {
      for (final fps in [24.0, 25.0, 30.0, 50.0, 59.94, 60.0]) {
        for (var i = 0; i < 200; i++) {
          expect(frameIndex(msOfFrame(i, fps), fps), i,
              reason: 'fps=$fps 第 $i 帧往返失真');
        }
      }
    });
  });

  group('相邻片段不共享任何一帧', () {
    test('上一段的最后一帧 + 1 就是下一段的第一帧', () {
      // 真实数据：S1 = [0, 2633)、S2 = [2633, 3933)
      final s1 = FrameSpan.fromMs(0, 2633, 30);
      final s2 = FrameSpan.fromMs(2633, 3933, 30);

      expect(s2.first, s1.last + 1,
          reason: '两段的帧区间必须首尾相接且不重叠——2633 那一帧属于 S2，'
              '播 S1 时把它放出来，用户看到的最后一画面就是 S2 的头');
      expect(s1.last, 78);
      expect(s2.first, 79);
    });

    test('整条片子逐段拼起来，帧序号连续无缝也无重叠', () {
      // 取真实任务里 U1 的五个镜头边界
      const bounds = [0, 2633, 3933, 5967, 9100, 14567];
      var expectedFirst = 0;
      for (var i = 0; i + 1 < bounds.length; i++) {
        final span = FrameSpan.fromMs(bounds[i], bounds[i + 1], 30);
        expect(span.first, expectedFirst, reason: '第 $i 段起始帧不连续');
        expectedFirst = span.last + 1;
      }
    });

    test('终点不是帧点时不多退一帧', () {
      const endMs = 92253; // 真实片长，不落在帧点上
      final span = FrameSpan.fromMs(0, endMs, 30);

      expect(span.lastMs, lessThan(endMs));
      expect(span.afterLastMs, greaterThanOrEqualTo(endMs));
    });

    test('只有一帧的片段：首尾同帧，不会算出负数长度', () {
      final span = FrameSpan.fromMs(0, msOfFrame(1, 30), 30);

      expect(span.first, 0);
      expect(span.last, 0);
      expect(span.frameCount, 1);
    });

    test('帧率非法时退化成一帧，不做除零', () {
      for (final fps in [0.0, -30.0, double.nan]) {
        final span = FrameSpan.fromMs(0, 2000, fps);
        expect(span.frameCount, 1);
        expect(span.firstMs, isNonNegative);
      }
    });
  });

  group('停止时刻落在最后一帧之内', () {
    test('严格晚于最后一帧的起点、早于下一帧', () {
      final span = FrameSpan.fromMs(0, 2633, 30);

      expect(span.withinLastFrameMs, greaterThanOrEqualTo(span.lastMs));
      expect(span.withinLastFrameMs, lessThan(span.afterLastMs),
          reason: '取到下一帧就会把下一段的头放出来（实测 mpv end=2.633 '
              '正是这个现象）；取到帧起点又会因取整落在边界上');
    });

    test('各帧率下都落在最后一帧的显示区间内', () {
      for (final fps in [24.0, 25.0, 30.0, 50.0, 59.94, 60.0]) {
        for (final endMs in [1000, 2633, 5967, 59987, 92253]) {
          final span = FrameSpan.fromMs(0, endMs, fps);
          expect(span.withinLastFrameMs, greaterThanOrEqualTo(span.lastMs),
              reason: 'fps=$fps endMs=$endMs');
          expect(span.withinLastFrameMs, lessThan(span.afterLastMs),
              reason: 'fps=$fps endMs=$endMs');
        }
      }
    });
  });
}
