import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/net/json_poster.dart';

ArkChatClient fakeChat(String reply, {void Function(String body)? onBody}) =>
    ArkChatClient(
      apiKey: 'k',
      post: (_, _, body) async {
        onBody?.call(body);
        return JsonPostResult(
            statusCode: 200,
            body: jsonEncode({
              'choices': [
                {'message': {'content': reply}}
              ]
            }));
      },
    );

void main() {
  test('parseVocabTags 过滤词表外标签', () {
    expect(
      parseVocabTags('{"tags":["功效演示","自由发挥的标签"]}', ['功效演示', '价格机制']),
      ['功效演示'],
    );
  });

  test('parseVocabTags 容忍 code fence 与非 JSON', () {
    expect(parseVocabTags('```json\n{"tags":["价格机制"]}\n```', ['价格机制']),
        ['价格机制']);
    expect(parseVocabTags('说不清', ['价格机制']), isEmpty);
  });

  test('UnitTagger 提交台词与词表并返回过滤后标签', () async {
    late String sentBody;
    final tagger = UnitTagger(
        chat: fakeChat('{"tags":["功效演示"]}', onBody: (b) => sentBody = b));
    final tags = await tagger.tag(
        transcript: '能把衣服洗干净', vocabulary: ['功效演示', '价格机制']);
    expect(tags, ['功效演示']);
    expect(sentBody, contains('能把衣服洗干净'));
    expect(sentBody, contains('功效演示'));
  });

  test('词表为空时不调用 LLM 返回空', () async {
    var called = false;
    final tagger = UnitTagger(
        chat: fakeChat('{"tags":[]}', onBody: (_) => called = true));
    expect(await tagger.tag(transcript: 'x', vocabulary: const []), isEmpty);
    expect(called, false);
  });

  test('ShotTagger 走 vision 通道传帧', () async {
    late String sentBody;
    final tagger = ShotTagger(
        chat: fakeChat('{"tags":["产品特写"]}', onBody: (b) => sentBody = b));
    final tags = await tagger
        .tag(frameJpeg: [9, 9, 9], vocabulary: ['产品特写', '人物口播']);
    expect(tags, ['产品特写']);
    expect(sentBody, contains('image_url'));
    expect(sentBody, contains(base64Encode([9, 9, 9])));
  });
}
