import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_usage.dart';
import 'package:ishkafel/features/tasks/task_metrics.dart';

void main() {
  group('等待时间：说人话', () {
    test('不到一分钟只说秒', () {
      expect(formatWaited(33400), '等待 33 秒');
    });

    test('超过一分钟说分和秒——「94 秒」要在脑子里除一次', () {
      expect(formatWaited(94000), '等待 1 分 34 秒');
    });

    test('整分不拖一个「0 秒」的尾巴', () {
      expect(formatWaited(120000), '等待 2 分');
    });

    test('不足一秒也不显示 0 秒', () {
      expect(formatWaited(400), '等待 1 秒');
    });

    test('还没测出来时不占位', () {
      expect(formatWaited(null), isNull);
    });
  });

  group('花费：不能给人一个偏低的数字', () {
    test('小额保留到分以下——一条片子就几分钱，四舍五入成 0.01 看不出差别', () {
      final usage = AiUsage.empty.plus(
          model: 'doubao-seed-2-0-mini-260428',
          promptTokens: 120000,
          completionTokens: 8000);

      // 120000/1e6*0.2 + 8000/1e6*2 = 0.024 + 0.016 = 0.04
      expect(formatCost(usage), '¥0.040');
    });

    test('金额大了就收敛到两位小数', () {
      final usage = AiUsage.empty.plus(
          model: 'doubao-seed-2-0-lite-260215',
          promptTokens: 20000000,
          completionTokens: 1000000);

      // 20*0.6 + 1*3.6 = 15.6
      expect(formatCost(usage), '¥15.60');
    });

    test('一次都没调用过就是 ¥0', () {
      expect(formatCost(AiUsage.empty), '¥0');
    });

    test('有算不出价的模型时如实说，不给一个偏低的数字', () {
      final usage = AiUsage.empty
          .plus(model: '新模型', promptTokens: 1000, completionTokens: 100);

      expect(formatCost(usage), '花费未知');
    });
  });

  group('明细：点开要能对账', () {
    test('逐个模型列出调用次数与 token', () {
      final usage = AiUsage.empty
          .plus(
              model: 'doubao-seed-2-0-mini-260428',
              promptTokens: 1000,
              completionTokens: 100)
          .plus(
              model: 'doubao-seed-2-0-mini-260428',
              promptTokens: 500,
              completionTokens: 50);

      expect(costBreakdown(usage), [
        'doubao-seed-2-0-mini-260428：2 次 · 输入 1500 · 输出 150 · ¥0.0006',
      ]);
    });

    test('算不出价的模型也列出来，标明算不出', () {
      final usage = AiUsage.empty
          .plus(model: '新模型', promptTokens: 10, completionTokens: 1);

      expect(costBreakdown(usage).single, contains('单价未知'));
    });

    test('没花过就没有明细', () {
      expect(costBreakdown(AiUsage.empty), isEmpty);
    });
  });
}
