import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/time/rational.dart';

/// **29.97 和 30 必须分得开。**
///
/// 现在 `frameMs(fps) = (1000/fps).round()` 对这两种帧率都返回 33ms，
/// 软件里完全分不开；而且 33×30 = 990ms，按「一帧 33 毫秒」累加每秒差 10ms，
/// 一分钟差 0.6 秒——界面显示的是帧，人看到的是「每段都对，加起来差一帧」。
void main() {
  group('两种帧率分得开', () {
    test('29.97 是 30000/1001，不是 29.97', () {
      expect(Rational.fps29_97.num, 30000);
      expect(Rational.fps29_97.den, 1001);
      expect(Rational.fps29_97, isNot(Rational.fps30));
    });

    test('进缓存 key 的字符串也不同——同一个 key 会命中错的切片', () {
      expect(Rational.fps29_97.toString(), '30000/1001');
      expect(Rational.fps30.toString(), '30');
    });
  });

  group('帧 ↔ 毫秒不再累加漂移', () {
    test('30fps：30 帧正好一秒', () {
      expect(Rational.fps30.framesToMs(30), 1000,
          reason: '按「一帧 33ms」算是 990ms，每秒差 10ms');
    });

    test('30fps：一分钟不差', () {
      expect(Rational.fps30.framesToMs(1800), 60000);
    });

    test('29.97：1001 帧正好 33.4 秒', () {
      expect(Rational.fps29_97.framesToMs(30000), 1001000);
    });

    test('毫秒转帧号向下取整——第 33ms 还在第 0 帧里', () {
      expect(Rational.fps30.msToFrames(0), 0);
      expect(Rational.fps30.msToFrames(33), 0);
      expect(Rational.fps30.msToFrames(34), 1);
      expect(Rational.fps30.msToFrames(1000), 30);
    });

    test('吸附用四舍五入——拖到 32ms 该吸到第 1 帧，不是退回第 0 帧', () {
      expect(Rational.fps30.msToNearestFrame(32), 1);
      expect(Rational.fps30.msToNearestFrame(16), 0);
      expect(Rational.fps30.msToNearestFrame(17), 1);
    });

    test('往返：帧 → 毫秒 → 帧 恒等', () {
      for (final fps in [Rational.fps24, Rational.fps25, Rational.fps29_97,
        Rational.fps30, Rational.fps59_94, Rational.fps60]) {
        for (final f in [0, 1, 7, 29, 30, 100, 1799, 1800, 5000]) {
          expect(fps.msToNearestFrame(fps.framesToMs(f)), f,
              reason: '$fps 的第 $f 帧转一圈回来变了');
        }
      }
    });
  });

  group('从 ffprobe 读', () {
    test('分数式原样读', () {
      expect(Rational.tryParse('30000/1001'), Rational.fps29_97);
      expect(Rational.tryParse('60/1'), Rational.fps60);
    });

    test('小数式认回标准帧率——29.97 要变回 30000/1001', () {
      expect(Rational.tryParse('29.97'), Rational.fps29_97);
      expect(Rational.tryParse('23.976'), Rational.fps23_976);
    });

    test('读不出来给 null，不瞎猜', () {
      expect(Rational.tryParse(''), isNull);
      expect(Rational.tryParse('abc'), isNull);
      expect(Rational.tryParse('30/0'), isNull);
    });

    test('老存档里的 double 也认得回来', () {
      expect(Rational.fromDouble(29.97), Rational.fps29_97);
      expect(Rational.fromDouble(30), Rational.fps30);
      expect(Rational.fromDouble(59.94), Rational.fps59_94);
    });

    test('认不出的怪帧率不丢掉，按千分之一保留', () {
      final odd = Rational.fromDouble(15.5);

      expect(odd.toDouble(), closeTo(15.5, 0.001));
    });

    test('0 或负数退回 30，不去除以 0', () {
      expect(Rational.fromDouble(0), Rational.fps30);
      expect(Rational.fromDouble(-5), Rational.fps30);
    });
  });

  group('约分与相等', () {
    test('60/2 和 30/1 是同一个帧率', () {
      expect(Rational(60, 2), Rational.fps30);
      expect(Rational(60, 2).hashCode, Rational.fps30.hashCode);
    });

    test('分母为负时符号归到分子', () {
      expect(Rational(30, -1).toString(), '-30');
    });

    test('分母为 0 直接抛——静默给个默认值只会把错误藏到更后面', () {
      expect(() => Rational(30, 0), throwsArgumentError);
    });
  });
}
