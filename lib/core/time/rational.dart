/// 帧率用**有理数**表示，不用 double。
///
/// 广播帧率天生是分数：29.97 其实是 30000/1001，23.976 是 24000/1001。
/// 用 double 存，`round()` 一下 29.97 和 30 就变成同一个数——现在
/// `frameMs(fps) = (1000/fps).round()` 对这两种帧率都返回 33ms，
/// 两种片子在软件里完全分不开（见
/// `docs/2026-09-08-成片时间轴重构-TRD.md` 二、2.5）。
///
/// 而且 33ms × 30 = 990ms，不是 1000ms：按「一帧 33 毫秒」一路累加，
/// 每秒差 10ms，一分钟就差 0.6 秒。界面显示的是帧，人看到的是
/// 「每一段都对，加起来差了一帧」。
library;

/// 一个约分过的有理数。分母恒为正
class Rational implements Comparable<Rational> {
  final int num;
  final int den;

  const Rational._(this.num, this.den);

  factory Rational(int numerator, int denominator) {
    if (denominator == 0) {
      throw ArgumentError.value(denominator, 'denominator', '分母不能为 0');
    }
    final sign = denominator < 0 ? -1 : 1;
    final n = numerator * sign;
    final d = denominator * sign;
    final g = _gcd(n.abs(), d);
    return Rational._(g == 0 ? 0 : n ~/ g, g == 0 ? 1 : d ~/ g);
  }

  static int _gcd(int a, int b) {
    while (b != 0) {
      final t = b;
      b = a % b;
      a = t;
    }
    return a;
  }

  /// 常见帧率。**不要用 double 去构造这些**——29.97 写成 29.97 就已经错了
  static const fps24 = Rational._(24, 1);
  static const fps25 = Rational._(25, 1);
  static const fps30 = Rational._(30, 1);
  static const fps50 = Rational._(50, 1);
  static const fps60 = Rational._(60, 1);

  /// 23.976（24000/1001）
  static const fps23_976 = Rational._(24000, 1001);

  /// 29.97（30000/1001）
  static const fps29_97 = Rational._(30000, 1001);

  /// 59.94（60000/1001）
  static const fps59_94 = Rational._(60000, 1001);

  /// 从 ffprobe 的 `r_frame_rate`（形如 `30000/1001`）读。读不出返回 null
  static Rational? tryParse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final slash = s.indexOf('/');
    if (slash < 0) {
      final d = double.tryParse(s);
      return d == null ? null : fromDouble(d);
    }
    final n = int.tryParse(s.substring(0, slash));
    final d = int.tryParse(s.substring(slash + 1));
    if (n == null || d == null || d == 0) return null;
    return Rational(n, d);
  }

  /// 从 double 猜一个帧率。
  ///
  /// **只在别无选择时用**（老存档里存的就是 double）：29.97 这类值先按
  /// 「离哪个标准帧率最近」认，认不出才退回 `round(x*1000)/1000`。
  /// 认得出的话 29.97 会变回精确的 30000/1001，而不是 29970/1000。
  static Rational fromDouble(double v) {
    if (v <= 0) return fps30;
    const known = [
      fps23_976, fps24, fps25, fps29_97, fps30, fps50, fps59_94, fps60,
    ];
    for (final k in known) {
      if ((k.toDouble() - v).abs() < 0.02) return k;
    }
    return Rational((v * 1000).round(), 1000);
  }

  double toDouble() => num / den;

  /// 这么多帧有多少毫秒（四舍五入到整毫秒）
  int framesToMs(int frames) => (frames * 1000 * den / num).round();

  /// 这么多毫秒是第几帧（向下取整——第 33ms 还在第 0 帧里）
  int msToFrames(int ms) => (ms * num / (1000 * den)).floor();

  /// 四舍五入到最近的帧号。定位、吸附用它；截长度用 [msToFrames]
  int msToNearestFrame(int ms) => (ms * num / (1000 * den)).round();

  @override
  bool operator ==(Object other) =>
      other is Rational && other.num == num && other.den == den;

  @override
  int get hashCode => Object.hash(num, den);

  @override
  int compareTo(Rational other) => (num * other.den).compareTo(other.num * den);

  /// 进缓存 key 用：`30000/1001`。两种帧率必须给出不同的字符串
  @override
  String toString() => den == 1 ? '$num' : '$num/$den';
}
