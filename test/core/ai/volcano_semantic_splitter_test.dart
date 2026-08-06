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

  test('索引有遗漏时按模型的切点补齐，台词一句不落', () async {
    final splitter = VolcanoSemanticSplitter(
        chat: fakeChat('{"units":[{"sentenceIndexes":[0]},{"sentenceIndexes":[2]}]}'));

    final drafts = await splitter.split(sentences);

    expect(drafts, hasLength(2), reason: '模型给了两个切点，就是两个单元');
    // 第 1 句没人认领，并进前一个单元——不能凭空丢掉
    expect(drafts[0].transcript, sentences[0].text + sentences[1].text);
    expect(drafts[1].transcript, sentences[2].text);
  });

  test('修复后的单元把每一句都收进去，不丢内容', () async {
    final splitter = VolcanoSemanticSplitter(
        chat: fakeChat('{"units":[{"sentenceIndexes":[0]},{"sentenceIndexes":[2]}]}'));

    final drafts = await splitter.split(sentences);

    final joined = drafts.map((d) => d.transcript).join();
    for (final s in sentences) {
      expect(joined, contains(s.text), reason: '丢一句台词，成片就缺一段');
    }
  });

  test('输出非 JSON 时回退每句一单元', () async {
    final splitter = VolcanoSemanticSplitter(chat: fakeChat('抱歉我不明白'));
    final drafts = await splitter.split(sentences);
    expect(drafts.length, 3);
  });

  group('降级要能被上层感知（用户以为「AI 就这水平」是最坏的结果）', () {
    test('输出非 JSON → 回调收到「无法解析」原因', () async {
      final reasons = <SemanticSplitDegradation>[];
      final splitter = VolcanoSemanticSplitter(
          chat: fakeChat('抱歉我不明白'), onDegraded: reasons.add);
      final drafts = await splitter.split(sentences);
      expect(drafts.length, 3);
      expect(reasons, [SemanticSplitDegradation.unparsableOutput]);
    });

    test('分组有瑕疵（遗漏句子）→ 按模型的切点补齐，而不是一句一个', () async {
      final reasons = <SemanticSplitDegradation>[];
      final splitter = VolcanoSemanticSplitter(
          chat: fakeChat('{"units":[{"sentenceIndexes":[0]}]}'),
          onDegraded: reasons.add);

      final drafts = await splitter.split(sentences);

      expect(drafts, hasLength(1),
          reason: '模型只给了一个切点，那就是一个单元——'
              '真机上「整份作废」把 27 句切成了 27 个单元');
      expect(reasons, [SemanticSplitDegradation.repairedPartition]);
    });

    test('分组彻底不可用（索引全越界）才退回一句一个', () async {
      final reasons = <SemanticSplitDegradation>[];
      final splitter = VolcanoSemanticSplitter(
          chat: fakeChat('{"units":[{"sentenceIndexes":[99]}]}'),
          onDegraded: reasons.add);

      expect((await splitter.split(sentences)), hasLength(3));
      expect(reasons, [SemanticSplitDegradation.invalidPartition]);
    });

    test('分组正常时不触发回调', () async {
      final reasons = <SemanticSplitDegradation>[];
      final splitter = VolcanoSemanticSplitter(
          chat: fakeChat(
              '{"units":[{"sentenceIndexes":[0,1]},{"sentenceIndexes":[2]}]}'),
          onDegraded: reasons.add);
      await splitter.split(sentences);
      expect(reasons, isEmpty);
    });

    test('未接回调时照常降级，不报错', () async {
      final splitter = VolcanoSemanticSplitter(chat: fakeChat('乱码'));
      expect((await splitter.split(sentences)).length, 3);
    });

    test('每个降级原因都带可直接展示的中文说明', () {
      for (final reason in SemanticSplitDegradation.values) {
        expect(reason.userMessage, contains('语义单元'));
        expect(reason.userMessage, isNot(contains('JSON')));
      }
    });
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
