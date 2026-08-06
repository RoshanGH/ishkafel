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

      // 12 万输入落在第二档（>32K）：0.4；输出 0.8 万按该档 4.0
      // 120000/1e6*0.4 + 8000/1e6*4 = 0.048 + 0.032 = 0.08
      expect(formatCost(usage), '¥0.080');
    });

    test('金额大了就收敛到两位小数', () {
      final usage = AiUsage.empty.plus(
          model: 'doubao-seed-2-0-lite-260215',
          promptTokens: 20000000,
          completionTokens: 1000000);

      // 2000 万输入远超最高档，按第三档：输入 1.8、输出 10.8
      // 20*1.8 + 1*10.8 = 46.8
      expect(formatCost(usage), '¥46.80');
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

      expect(costBreakdown(usage).first,
          'doubao-seed-2-0-mini-260428：2 次 · 输入 1500 · 输出 150 · ¥0.0006');
    });

    test('算不出价的模型也列出来，标明算不出', () {
      final usage = AiUsage.empty
          .plus(model: '新模型', promptTokens: 10, completionTokens: 1);

      expect(costBreakdown(usage).first, contains('单价未知'));
    });

    test('没花过就没有明细', () {
      expect(costBreakdown(AiUsage.empty), isEmpty);
    });
  });

  group('语音服务也要出现在明细里', () {
    test('语音识别按秒列出，换算成钱', () {
      final usage = AiUsage.empty
          .plusService(service: SpeechService.asrFlash, quantity: 96);

      expect(costBreakdown(usage).first,
          '语音识别（极速版）：1 次 · 96 秒 · ¥0.1200');
    });

    test('语音合成按字符列出', () {
      final usage = AiUsage.empty
          .plusService(service: SpeechService.tts, quantity: 200);

      expect(costBreakdown(usage).first, '语音合成：1 次 · 200 字符 · ¥0.0600');
    });

    test('末尾注明是折算值——账号常是共用的，这不等于账单', () {
      final usage = AiUsage.empty
          .plusService(service: SpeechService.tts, quantity: 200);

      expect(costBreakdown(usage).last, contains('未计免费额度'));
    });
  });
}
