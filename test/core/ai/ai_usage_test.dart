import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_usage.dart';

void main() {
  group('按模型分开记账——单价不同，混在一起算不出钱', () {
    test('累加同一个模型的多次调用', () {
      final usage = AiUsage.empty
          .plus(model: 'mini', promptTokens: 100, completionTokens: 20)
          .plus(model: 'mini', promptTokens: 50, completionTokens: 10);

      expect(usage.calls, 2);
      expect(usage.promptTokens, 150);
      expect(usage.completionTokens, 30);
    });

    test('不同模型各记各的', () {
      final usage = AiUsage.empty
          .plus(model: 'a', promptTokens: 100, completionTokens: 10)
          .plus(model: 'b', promptTokens: 200, completionTokens: 20);

      expect(usage.byModel.keys, ['a', 'b']);
      expect(usage.byModel['b']!.promptTokens, 200);
      expect(usage.calls, 2);
    });

    test('累加不改原来的那份', () {
      final before = AiUsage.empty
          .plus(model: 'a', promptTokens: 10, completionTokens: 1);
      final after =
          before.plus(model: 'a', promptTokens: 10, completionTokens: 1);

      expect(before.calls, 1, reason: '就地改会让「这次分析花了多少」永远算不准');
      expect(after.calls, 2);
    });

    test('两份用量能合并——后台打标与主流程各记一份', () {
      final a = AiUsage.empty
          .plus(model: 'mini', promptTokens: 10, completionTokens: 1);
      final b = AiUsage.empty
          .plus(model: 'mini', promptTokens: 5, completionTokens: 2)
          .plus(model: 'lite', promptTokens: 7, completionTokens: 3);

      final merged = a.merge(b);

      expect(merged.calls, 3);
      expect(merged.byModel['mini']!.promptTokens, 15);
      expect(merged.byModel['lite']!.completionTokens, 3);
    });
  });

  group('算钱', () {
    test('输入输出分别按各自单价算', () {
      // mini 第一档（输入 ≤32K）：输入 ¥0.2 / 输出 ¥2.0 每百万 token
      final usage = AiUsage.empty.plus(
          model: 'doubao-seed-2-0-mini-260428',
          promptTokens: 30000,
          completionTokens: 1000000);

      expect(usage.costYuan,
          closeTo(30000 / 1e6 * 0.2 + 1000000 / 1e6 * 2.0, 0.0001));
    });

    test('多个模型的钱加起来', () {
      final usage = AiUsage.empty
          .plus(
              model: 'doubao-seed-2-0-mini-260428',
              promptTokens: 30000,
              completionTokens: 0)
          .plus(
              model: 'doubao-seed-2-0-lite-260215',
              promptTokens: 30000,
              completionTokens: 0);

      expect(usage.costYuan,
          closeTo(30000 / 1e6 * 0.2 + 30000 / 1e6 * 0.6, 0.0001));
    });

    test('不认识的模型算不出钱，如实说不知道，不悄悄按 0 算', () {
      final usage = AiUsage.empty
          .plus(model: '没见过的模型', promptTokens: 1000000, completionTokens: 0);

      expect(usage.costYuan, isNull,
          reason: '按 0 算会让用户以为这次没花钱');
      expect(usage.unpricedModels, ['没见过的模型']);
    });

    test('认识的和不认识的混在一起时，仍然算不出总数', () {
      final usage = AiUsage.empty
          .plus(
              model: 'doubao-seed-2-0-mini-260428',
              promptTokens: 1000000,
              completionTokens: 0)
          .plus(model: '没见过的', promptTokens: 10, completionTokens: 0);

      expect(usage.costYuan, isNull);
    });

    test('没花过就是 0，不是「不知道」', () {
      expect(AiUsage.empty.costYuan, 0);
    });

    test('同系列不同日期的模型走同一份单价', () {
      final a = AiUsage.empty.plus(
          model: 'doubao-seed-2-0-lite-260428',
          promptTokens: 30000,
          completionTokens: 0);

      expect(a.costYuan, closeTo(30000 / 1e6 * 0.6, 0.0001),
          reason: '按模型全名逐个列价，换一个日期后缀就算不出钱了');
    });
  });

  group('存得住', () {
    test('存了再读回来是同一份账', () {
      final usage = AiUsage.empty
          .plus(model: 'mini', promptTokens: 10, completionTokens: 2)
          .plus(model: 'lite', promptTokens: 5, completionTokens: 1);

      final back = AiUsage.fromJson(usage.toJson());

      expect(back.calls, usage.calls);
      expect(back.byModel['mini']!.promptTokens, 10);
      expect(back.byModel['lite']!.completionTokens, 1);
    });

    test('老任务没有这个字段时当作没花过，不炸', () {
      expect(AiUsage.fromJson(null).calls, 0);
      expect(AiUsage.fromJson('乱七八糟').calls, 0);
    });

    test('字段类型不对的条目跳过，不牵连其余', () {
      final back = AiUsage.fromJson({
        'byModel': {
          'mini': {'calls': 1, 'promptTokens': 10, 'completionTokens': 2},
          'huai': '不是个对象',
        }
      });

      expect(back.byModel.keys, ['mini']);
    });
  });
}
