import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_usage.dart';

void main() {
  group('分段计费：单价按「这一次请求」的输入长度定档', () {
    test('小请求走第一档', () {
      expect(ArkPricing.tierOf(model: 'doubao-seed-2-0-mini-260428', promptTokens: 3000),
          0);
    });

    test('刚好 32K 还在第一档，超一个 token 就进第二档', () {
      const model = 'doubao-seed-2-0-mini-260428';
      expect(ArkPricing.tierOf(model: model, promptTokens: 32000), 0);
      expect(ArkPricing.tierOf(model: model, promptTokens: 32001), 1);
    });

    test('超过最高档就按最高档算，不返回「不知道」', () {
      expect(
          ArkPricing.tierOf(
              model: 'doubao-seed-2-0-mini-260428', promptTokens: 999999),
          2,
          reason: '越界时说不知道会让整个花费变成未知，而实际是照扣钱的');
    });

    test('不认识的模型没有档位', () {
      expect(ArkPricing.tierOf(model: '没见过的', promptTokens: 100), isNull);
    });
  });

  group('单价照官方表', () {
    test('mini 第一档：输入 0.2、缓存命中 0.04、输出 2.0', () {
      expect(
          ArkPricing.costOf(
              model: 'doubao-seed-2-0-mini-260428',
              tier: 0,
              prompt: 1000000,
              cached: 0,
              completion: 0),
          closeTo(0.2, 1e-9));
      expect(
          ArkPricing.costOf(
              model: 'doubao-seed-2-0-mini-260428',
              tier: 0,
              prompt: 0,
              cached: 1000000,
              completion: 0),
          closeTo(0.04, 1e-9));
      expect(
          ArkPricing.costOf(
              model: 'doubao-seed-2-0-mini-260428',
              tier: 0,
              prompt: 0,
              cached: 0,
              completion: 1000000),
          closeTo(2.0, 1e-9));
    });

    test('mini 第二档整体翻倍', () {
      expect(
          ArkPricing.costOf(
              model: 'doubao-seed-2-0-mini-260428',
              tier: 1,
              prompt: 1000000,
              cached: 0,
              completion: 1000000),
          closeTo(0.4 + 4.0, 1e-9));
    });

    test('lite 第一档：0.6 / 0.12 / 3.6', () {
      expect(
          ArkPricing.costOf(
              model: 'doubao-seed-2-0-lite-260215',
              tier: 0,
              prompt: 1000000,
              cached: 1000000,
              completion: 1000000),
          closeTo(0.6 + 0.12 + 3.6, 1e-9));
    });

    test('pro 第一档是 3.2 / 16，不是我先前猜的 2.4 / 24', () {
      expect(
          ArkPricing.costOf(
              model: 'doubao-seed-2-0-pro-260215',
              tier: 0,
              prompt: 1000000,
              cached: 0,
              completion: 1000000),
          closeTo(3.2 + 16.0, 1e-9));
    });

    test('缓存命中比输入便宜——正好五分之一', () {
      final input = ArkPricing.costOf(
          model: 'doubao-seed-2-0-mini-260428',
          tier: 0,
          prompt: 1000000,
          cached: 0,
          completion: 0)!;
      final cached = ArkPricing.costOf(
          model: 'doubao-seed-2-0-mini-260428',
          tier: 0,
          prompt: 0,
          cached: 1000000,
          completion: 0)!;

      expect(cached, closeTo(input / 5, 1e-9));
    });

    test('不认识的模型算不出钱', () {
      expect(
          ArkPricing.costOf(
              model: '没见过的', tier: 0, prompt: 100, cached: 0, completion: 0),
          isNull);
    });
  });

  group('用量按档位分开累计——不能先加总再定档', () {
    test('两次不同档的请求各按各的单价算', () {
      final usage = AiUsage.empty
          .plus(
              model: 'doubao-seed-2-0-mini-260428',
              promptTokens: 1000000,
              completionTokens: 0)
          .plus(
              model: 'doubao-seed-2-0-mini-260428',
              promptTokens: 40000,
              completionTokens: 0);

      // 第一次 100 万 token 落在第三档（>128K）：0.8
      // 第二次 4 万落在第二档：0.4
      expect(usage.costYuan,
          closeTo(1000000 / 1e6 * 0.8 + 40000 / 1e6 * 0.4, 1e-9));
    });

    test('先加总再定档会算错——这正是要避免的', () {
      final usage = AiUsage.empty.plus(
          model: 'doubao-seed-2-0-mini-260428',
          promptTokens: 3000,
          completionTokens: 0);

      expect(usage.costYuan, closeTo(3000 / 1e6 * 0.2, 1e-9),
          reason: '3000 token 是第一档，按 0.2 算');
    });

    test('缓存命中的部分不再按输入价重复计一遍', () {
      final usage = AiUsage.empty.plus(
          model: 'doubao-seed-2-0-mini-260428',
          promptTokens: 10000,
          cachedTokens: 4000,
          completionTokens: 0);

      // 官方口径：未命中的按输入价，命中的按缓存价
      expect(usage.costYuan,
          closeTo(6000 / 1e6 * 0.2 + 4000 / 1e6 * 0.04, 1e-9));
    });

    test('展示用的输入 token 仍是总数，用户对得上账单', () {
      final usage = AiUsage.empty.plus(
          model: 'doubao-seed-2-0-mini-260428',
          promptTokens: 10000,
          cachedTokens: 4000,
          completionTokens: 0);

      expect(usage.promptTokens, 10000);
      expect(usage.cachedTokens, 4000);
    });
  });

  group('老存档读得回来', () {
    test('没有档位信息的旧格式当作第一档', () {
      final back = AiUsage.fromJson({
        'byModel': {
          'doubao-seed-2-0-mini-260428': {
            'calls': 2,
            'promptTokens': 1000,
            'completionTokens': 100,
          }
        }
      });

      expect(back.calls, 2);
      expect(back.promptTokens, 1000);
      expect(back.costYuan,
          closeTo(1000 / 1e6 * 0.2 + 100 / 1e6 * 2.0, 1e-9));
    });

    test('新格式存了再读是同一份账', () {
      final usage = AiUsage.empty
          .plus(
              model: 'doubao-seed-2-0-mini-260428',
              promptTokens: 40000,
              cachedTokens: 1000,
              completionTokens: 500)
          .plus(
              model: 'doubao-seed-2-0-mini-260428',
              promptTokens: 3000,
              completionTokens: 200);

      final back = AiUsage.fromJson(usage.toJson());

      expect(back.calls, 2);
      expect(back.promptTokens, 43000);
      expect(back.cachedTokens, 1000);
      expect(back.costYuan, closeTo(usage.costYuan!, 1e-9));
    });
  });
}
