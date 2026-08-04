import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/audio/delivery_analyzer.dart';
import 'package:ishkafel/core/audio/prosody_profile.dart';
import 'package:ishkafel/core/net/json_poster.dart';

late String sentBody;

ArkChatClient _chat(String reply) => ArkChatClient(
      apiKey: 'k',
      post: (_, _, body) async {
        sentBody = body;
        return JsonPostResult(
          statusCode: 200,
          body: jsonEncode({
            'choices': [
              {'message': {'content': reply}}
            ]
          }),
        );
      },
    );

const _wav = [82, 73, 70, 70, 1, 2, 3, 4];

const _prosody = ProsodyProfile(
  charsPerSec: 4.1,
  pace: Pace.fast,
  pauseCount: 1,
  longestPauseMs: 120,
  stressedWords: ['69.9'],
  hasSignal: true,
);

void main() {
  group('把原声送去听，拿回一句可执行的语音指令', () {
    test('解析出描述与指令', () async {
      final a = await ArkDeliveryAnalyzer(
              chat: _chat(jsonEncode({
        'description': '急切的推销语气，重音落在价格上',
        'instruction': '你可以用急促、有压迫感的语气催促观众吗？重音落在价格上。',
      })))
          .analyze(audioWav: _wav, transcript: '再不买就恢复69.9一瓶了。');

      expect(a.instruction, contains('急促'));
      expect(a.description, contains('推销'));
      expect(a.rawReply, isNotNull, reason: '原样回复要留痕，解析出错时靠它定位');
    });

    test('音频确实被送出去了，而且用的是能听音频的模型', () async {
      await ArkDeliveryAnalyzer(chat: _chat('{}'))
          .analyze(audioWav: _wav, transcript: '台词');

      expect(sentBody, contains('input_audio'));
      expect(sentBody, contains(base64Encode(_wav)));
      expect(sentBody, contains('260428'),
          reason: '同批次的 260215 报「audio input is not supported」，'
              '默认模型必须是支持音频的那一版');
    });

    test('客观测量作为佐证一起送进去——防止模型顺着台词脑补', () async {
      await ArkDeliveryAnalyzer(chat: _chat('{}')).analyze(
          audioWav: _wav, transcript: '再不买就恢复69.9一瓶了。', prosody: _prosody);

      expect(sentBody, contains('69.9'));
      expect(sentBody, contains('4.1'));
    });

    test('没有测量数据时不硬塞一段空的「客观测量：」', () async {
      await ArkDeliveryAnalyzer(chat: _chat('{}')).analyze(
        audioWav: _wav,
        transcript: '台词',
        prosody: const ProsodyProfile(
          charsPerSec: 0,
          pace: Pace.normal,
          pauseCount: 0,
          longestPauseMs: 0,
          stressedWords: [],
          hasSignal: false,
        ),
      );

      expect(sentBody, isNot(contains('客观测量')));
    });

    test('提示词要求只描述念法，不复述台词', () async {
      await ArkDeliveryAnalyzer(chat: _chat('{}'))
          .analyze(audioWav: _wav, transcript: '台词');

      expect(sentBody, contains('不要复述台词'));
    });
  });

  group('模型不配合时', () {
    test('回复不是 JSON 时给空指令，而不是编一句', () async {
      final a = await ArkDeliveryAnalyzer(chat: _chat('今天不想输出 JSON'))
          .analyze(audioWav: _wav, transcript: '台词');

      expect(a.instruction, isEmpty,
          reason: '瞎猜一句语音指令会让整段配音跑偏；没有指令只是退回默认念法');
      expect(a.rawReply, '今天不想输出 JSON');
    });

    test('指令是空串时同样当作没有', () async {
      final a = await ArkDeliveryAnalyzer(
              chat: _chat(jsonEncode({'description': 'x', 'instruction': '   '})))
          .analyze(audioWav: _wav, transcript: '台词');

      expect(a.instruction, isEmpty);
    });
  });

  group('落盘往返', () {
    test('存下来再读回来还是那句指令', () {
      const a = DeliveryAnalysis(
          description: '急切', instruction: '你可以用急促的语气说吗？');

      final back = DeliveryAnalysis.tryFromJson(a.toJson());

      expect(back!.instruction, '你可以用急促的语气说吗？');
      expect(back.description, '急切');
    });

    test('畸形或缺指令时返回 null', () {
      expect(DeliveryAnalysis.tryFromJson('不是对象'), isNull);
      expect(DeliveryAnalysis.tryFromJson({'description': '只有描述'}), isNull);
    });
  });
}
