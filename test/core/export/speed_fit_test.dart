import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/speed_fit.dart';

void main() {
  group('变速倍率 = 候选时长 ÷ 坑位时长', () {
    test('候选比坑位长就加速', () {
      expect(SpeedFit.factorFor(candidateMs: 4500, slotMs: 3000), closeTo(1.5, 1e-9));
    });

    test('候选比坑位短就放慢', () {
      expect(SpeedFit.factorFor(candidateMs: 2400, slotMs: 3000), closeTo(0.8, 1e-9));
    });

    test('一样长就是 1 倍，不做任何变速', () {
      expect(SpeedFit.factorFor(candidateMs: 3000, slotMs: 3000), 1.0);
    });

    test('坑位为 0 时给 1 倍，不产生除零', () {
      expect(SpeedFit.factorFor(candidateMs: 3000, slotMs: 0), 1.0);
    });
  });

  group('说人话', () {
    test('加速时说加速几倍', () {
      expect(SpeedFit.describe(1.5), '加速 1.5×');
    });

    test('放慢时说放慢几倍', () {
      expect(SpeedFit.describe(0.8), '放慢 0.8×');
    });

    test('几乎一样长就说不变速——1.02× 写出来只是噪音', () {
      expect(SpeedFit.describe(1.0), isNull);
      expect(SpeedFit.describe(1.01), isNull);
      expect(SpeedFit.describe(0.99), isNull);
    });

    test('大倍率如实描述——倍率不设上限，但要让用户看见', () {
      expect(SpeedFit.describe(3.3), '加速 3.3×');
      expect(SpeedFit.describe(10.0), '加速 10×');
      expect(SpeedFit.describe(0.33), '放慢 0.3×');
    });
  });
}
