import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_usage.dart';

void main() {
  group('按时长/字符计费的服务，和按 token 的分开记', () {
    test('语音识别按音频秒数累计', () {
      final usage = AiUsage.empty
          .plusService(service: SpeechService.asrFlash, quantity: 96)
          .plusService(service: SpeechService.asrFlash, quantity: 30);

      final asr = usage.byService[SpeechService.asrFlash]!;
      expect(asr.calls, 2);
      expect(asr.quantity, 126);
    });

    test('语音识别 4.5 元/小时——96 秒就是 0.12 元', () {
      final usage = AiUsage.empty
          .plusService(service: SpeechService.asrFlash, quantity: 96);

      expect(usage.costYuan, closeTo(96 / 3600 * 4.5, 0.0001));
    });

    test('语音合成 3 元/万字符，一个汉字算一个字符', () {
      final usage = AiUsage.empty
          .plusService(service: SpeechService.tts, quantity: 200);

      expect(usage.costYuan, closeTo(200 / 10000 * 3.0, 0.0001));
    });

    test('复刻音色与预置音色同价，但分开记账——用户要看得出钱花在哪', () {
      final usage = AiUsage.empty
          .plusService(service: SpeechService.tts, quantity: 100)
          .plusService(service: SpeechService.voiceClone, quantity: 100);

      expect(usage.byService.keys,
          [SpeechService.tts, SpeechService.voiceClone]);
      expect(usage.costYuan, closeTo(200 / 10000 * 3.0, 0.0001));
    });

    test('token 的钱和按量的钱加在一起', () {
      final usage = AiUsage.empty
          .plus(
              model: 'doubao-seed-2-0-mini-260428',
              promptTokens: 1000000,
              completionTokens: 0)
          .plusService(service: SpeechService.asrFlash, quantity: 3600);

      expect(usage.costYuan, closeTo(0.2 + 4.5, 0.0001));
    });

    test('累加不改原来的那份', () {
      final before =
          AiUsage.empty.plusService(service: SpeechService.tts, quantity: 10);
      before.plusService(service: SpeechService.tts, quantity: 10);

      expect(before.byService[SpeechService.tts]!.quantity, 10);
    });

    test('合并两份账时按量的也要合上', () {
      final a =
          AiUsage.empty.plusService(service: SpeechService.tts, quantity: 10);
      final b = AiUsage.empty
          .plusService(service: SpeechService.tts, quantity: 5)
          .plusService(service: SpeechService.asrFlash, quantity: 60);

      final merged = a.merge(b);

      expect(merged.byService[SpeechService.tts]!.quantity, 15);
      expect(merged.byService[SpeechService.asrFlash]!.calls, 1);
    });

    test('存了再读回来是同一份账', () {
      final usage = AiUsage.empty
          .plusService(service: SpeechService.asrFlash, quantity: 96)
          .plusService(service: SpeechService.tts, quantity: 200);

      final back = AiUsage.fromJson(usage.toJson());

      expect(back.byService[SpeechService.asrFlash]!.quantity, 96);
      expect(back.byService[SpeechService.tts]!.quantity, 200);
    });

    test('存档里出现不认识的服务名时跳过，不炸也不算错钱', () {
      final back = AiUsage.fromJson({
        'byService': {
          'asrFlash': {'calls': 1, 'quantity': 96},
          '未来才有的服务': {'calls': 1, 'quantity': 5},
        }
      });

      expect(back.byService.keys, [SpeechService.asrFlash]);
    });

    test('调用次数把两边都算上', () {
      final usage = AiUsage.empty
          .plus(model: 'mini', promptTokens: 1, completionTokens: 1)
          .plusService(service: SpeechService.asrFlash, quantity: 96);

      expect(usage.calls, 2);
    });
  });
}
