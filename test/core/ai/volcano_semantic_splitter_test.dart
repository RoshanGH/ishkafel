import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/volcano_semantic_splitter.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/net/json_poster.dart';

const sentences = [
  AsrSentence(startMs: 0, endMs: 3000, text: '衣服洗完还是有异味？'),
  AsrSentence(startMs: 3100, endMs: 6000, text: '其实是细菌没除干净。'),
  AsrSentence(startMs: 6200, endMs: 9000, text: '现在只要29块9。'),
];

ArkChatClient fakeChat(String reply) => ArkChatClient(
      apiKey: 'k',
      post: (_, _, _) async => JsonPostResult(
          statusCode: 200,
          body: jsonEncode({
            'choices': [
              {'message': {'content': reply}}
            ]
          })),
    );

void main() {
  test('按索引分组并由句子时间戳推导边界', () async {
    final splitter = VolcanoSemanticSplitter(
        chat: fakeChat('{"units":[{"sentenceIndexes":[0,1]},{"sentenceIndexes":[2]}]}'));
    final drafts = await splitter.split(sentences);
    expect(drafts.length, 2);
    expect(drafts[0].startMs, 0);
    expect(drafts[0].endMs, 6000);
    expect(drafts[0].transcript, '衣服洗完还是有异味？其实是细菌没除干净。');
    expect(drafts[1].startMs, 6200);
    expect(drafts[1].endMs, 9000);
  });

  test('剥掉 markdown code fence 后解析', () async {
    final splitter = VolcanoSemanticSplitter(
        chat: fakeChat(
            '```json\n{"units":[{"sentenceIndexes":[0,1,2]}]}\n```'));
    final drafts = await splitter.split(sentences);
    expect(drafts.length, 1);
    expect(drafts.single.endMs, 9000);
  });

  test('索引不合法（遗漏句子）时回退每句一单元', () async {
    final splitter = VolcanoSemanticSplitter(
        chat: fakeChat('{"units":[{"sentenceIndexes":[0]}]}'));
    final drafts = await splitter.split(sentences);
    expect(drafts.length, 3);
    expect(drafts[2].transcript, '现在只要29块9。');
  });

  test('输出非 JSON 时回退每句一单元', () async {
    final splitter = VolcanoSemanticSplitter(chat: fakeChat('抱歉我不明白'));
    final drafts = await splitter.split(sentences);
    expect(drafts.length, 3);
  });

  test('空输入返回空且不调用 LLM', () async {
    var called = false;
    final chat = ArkChatClient(
      apiKey: 'k',
      post: (_, _, _) async {
        called = true;
        return const JsonPostResult(statusCode: 200, body: '{}');
      },
    );
    final drafts =
        await VolcanoSemanticSplitter(chat: chat).split(const []);
    expect(drafts, isEmpty);
    expect(called, false);
  });
}
