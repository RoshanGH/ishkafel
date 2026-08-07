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

  group('允许范围 0.8×~2.0×', () {
    test('3 秒坑位可用 2.4~6.0 秒的候选', () {
      expect(SpeedFit.allows(SpeedFit.factorFor(candidateMs: 2400, slotMs: 3000)), isTrue);
      expect(SpeedFit.allows(SpeedFit.factorFor(candidateMs: 6000, slotMs: 3000)), isTrue);
      expect(SpeedFit.allows(SpeedFit.factorFor(candidateMs: 4500, slotMs: 3000)), isTrue);
    });

    test('加速超过 2 倍不行——3 秒坑位塞 10 秒素材是快进', () {
      expect(SpeedFit.allows(SpeedFit.factorFor(candidateMs: 10000, slotMs: 3000)),
          isFalse);
    });

    test('放慢低于 0.8 倍不行——每帧显示两遍，明显卡顿', () {
      expect(SpeedFit.allows(SpeedFit.factorFor(candidateMs: 1000, slotMs: 3000)),
          isFalse);
    });

    test('边界含在内', () {
      expect(SpeedFit.allows(0.8), isTrue);
      expect(SpeedFit.allows(2.0), isTrue);
      expect(SpeedFit.allows(0.79), isFalse);
      expect(SpeedFit.allows(2.01), isFalse);
    });

    test('浮点误差不该把刚好卡边界的判成越界', () {
      // 2.4s / 3.0s 在二进制浮点下不是精确的 0.8
      expect(SpeedFit.allows(SpeedFit.factorFor(candidateMs: 2400, slotMs: 3000)),
          isTrue);
      expect(SpeedFit.allows(SpeedFit.factorFor(candidateMs: 6000, slotMs: 3000)),
          isTrue);
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

    test('越界时的说明要带上能用的时长范围，用户才知道该找多长的', () {
      final why = SpeedFit.rejectReason(candidateMs: 10000, slotMs: 3000);

      expect(why, isNotNull);
      expect(why, contains('2.4'));
      expect(why, contains('6.0'));
    });

    test('在范围内就没有拒绝理由', () {
      expect(SpeedFit.rejectReason(candidateMs: 4500, slotMs: 3000), isNull);
    });
  });
}
