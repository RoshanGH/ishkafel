import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/speech_alignment.dart';

void main() {
  group('把合成语速调到贴近原声时长', () {
    test('合成偏慢时加速', () {
      // 原声 2520ms，合成 3072ms → 慢了 22%
      final rate = SpeechAlignment.rateFor(
          synthesizedMs: 3072, targetMs: 2520);

      expect(rate, greaterThan(0),
          reason: 'speech_rate 为正表示加速（实测 50 → 2016ms）');
    });

    test('合成偏快时减速', () {
      expect(SpeechAlignment.rateFor(synthesizedMs: 2000, targetMs: 2520),
          lessThan(0));
    });

    test('已经很接近就不动——为了几十毫秒改语速反而听得出来', () {
      expect(SpeechAlignment.rateFor(synthesizedMs: 2540, targetMs: 2520), 0);
    });

    test('夹在接口允许的范围内，不发一个会被拒的值', () {
      final tooSlow =
          SpeechAlignment.rateFor(synthesizedMs: 20000, targetMs: 1000);
      final tooFast =
          SpeechAlignment.rateFor(synthesizedMs: 500, targetMs: 20000);

      expect(tooSlow, lessThanOrEqualTo(SpeechAlignment.maxRate));
      expect(tooFast, greaterThanOrEqualTo(SpeechAlignment.minRate));
    });

    test('目标或合成时长非法时不调整，交给上层兜底', () {
      expect(SpeechAlignment.rateFor(synthesizedMs: 0, targetMs: 2520), 0);
      expect(SpeechAlignment.rateFor(synthesizedMs: 2520, targetMs: 0), 0);
    });
  });

  group('剩下的误差用变速滤镜补齐', () {
    test('给出 ffmpeg atempo 的倍率', () {
      final tempo =
          SpeechAlignment.tempoFor(actualMs: 2600, targetMs: 2520);

      expect(tempo, closeTo(2600 / 2520, 0.001));
    });

    test('差在可忽略范围内时返回 1（不加滤镜）', () {
      expect(SpeechAlignment.tempoFor(actualMs: 2530, targetMs: 2520), 1.0,
          reason: '为十毫秒挂一道重采样，白白引入音质损失');
    });

    test('atempo 单次只支持 0.5~2.0，超出要拆成多级', () {
      final chain = SpeechAlignment.tempoChain(3.5);

      expect(chain, isNotEmpty);
      expect(chain.every((t) => t >= 0.5 && t <= 2.0), isTrue,
          reason: '单个 atempo 超出 0.5~2.0，ffmpeg 直接报错');
      final product = chain.fold<double>(1, (a, b) => a * b);
      expect(product, closeTo(3.5, 0.001));
    });

    test('在范围内时就一级，不做无谓的串联', () {
      expect(SpeechAlignment.tempoChain(1.2), [1.2]);
    });

    test('倍率为 1 时返回空链——不加滤镜', () {
      expect(SpeechAlignment.tempoChain(1.0), isEmpty);
    });

    test('非法倍率不产生会让 ffmpeg 报错的滤镜', () {
      expect(SpeechAlignment.tempoChain(0), isEmpty);
      expect(SpeechAlignment.tempoChain(-1), isEmpty);
    });
  });

  group('滤镜表达式', () {
    test('多级串联用逗号连接', () {
      final expr = SpeechAlignment.atempoFilter(3.5);

      expect(expr, isNotNull);
      expect(expr!.split(',').length, greaterThan(1));
      expect(expr, startsWith('atempo='));
    });

    test('不需要变速时为 null，调用方据此整段跳过滤镜', () {
      expect(SpeechAlignment.atempoFilter(1.0), isNull);
    });
  });
}
