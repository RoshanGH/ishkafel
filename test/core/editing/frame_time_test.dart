import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/frame_time.dart';

void main() {
  group('帧点换算', () {
    test('30fps 的帧点在毫秒轴上非等距（33/34 交替）', () {
      final points = [for (var i = 0; i < 5; i++) msOfFrame(i, 30)];

      expect(points, [0, 33, 67, 100, 133],
          reason: '正因为非等距，「往前一帧」不能用 ms 域常数偏移，'
              '必须回到帧序号域加减');
    });

    test('毫秒 → 帧序号 → 毫秒 在帧点上可往返', () {
      for (final fps in [24.0, 25.0, 30.0, 50.0, 59.94, 60.0]) {
        for (var i = 0; i < 200; i++) {
          final ms = msOfFrame(i, fps);
          expect(frameIndex(ms, fps), i, reason: 'fps=$fps 第 $i 帧往返失真');
        }
      }
    });
  });

  group('片段的最后一帧', () {
    test('相邻片段无缝覆盖：上一段的最后一帧不等于下一段的第一帧', () {
      // S1 = [0, 2000)、S2 = [2000, 5000)
      final lastOfS1 = lastFrameBefore(2000, 30);

      expect(lastOfS1, lessThan(2000));
      expect(lastOfS1, msOfFrame(frameIndex(2000, 30) - 1, 30),
          reason: '停在 endMs 上就是停在**下一段**的第一帧——'
              '用户双击 S1 却看到 S2 的画面');
    });

    test('终点不是帧点时，取严格小于它的最大帧点', () {
      // 真实片长是外部数据，常常不落在帧点上
      const endMs = 92253;
      final last = lastFrameBefore(endMs, 30);

      expect(last, lessThan(endMs));
      expect(msOfFrame(frameIndex(last, 30) + 1, 30),
          greaterThanOrEqualTo(endMs),
          reason: '它必须是「小于终点的最大帧点」，不能再往前多退一帧');
    });

    test('终点恰在第 1 帧时退回第 0 帧', () {
      expect(lastFrameBefore(msOfFrame(1, 30), 30), 0);
    });

    test('终点已经是 0 或负数时给 0，不返回负时间', () {
      expect(lastFrameBefore(0, 30), 0);
      expect(lastFrameBefore(-100, 30), 0);
    });

    test('各帧率下都严格小于终点', () {
      for (final fps in [24.0, 25.0, 30.0, 50.0, 59.94, 60.0]) {
        for (final endMs in [1, 33, 100, 999, 3984, 59987, 92253]) {
          final last = lastFrameBefore(endMs, fps);
          expect(last, lessThan(endMs),
              reason: 'fps=$fps endMs=$endMs 没有严格小于终点');
          expect(last, greaterThanOrEqualTo(0));
        }
      }
    });

    test('帧率非法时不做除零，退回终点前 1ms', () {
      expect(lastFrameBefore(2000, 0), 1999);
      expect(lastFrameBefore(2000, -30), 1999);
      expect(lastFrameBefore(2000, double.nan), 1999);
    });
  });
}
