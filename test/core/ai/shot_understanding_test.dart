import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/net/json_poster.dart';

/// 记录最后一次请求体，便于断言「到底送了几帧」
late String lastBody;

ArkChatClient _chat(String reply) => ArkChatClient(
      apiKey: 'x',
      post: (_, _, body) async {
        lastBody = body;
        return JsonPostResult(
          statusCode: 200,
          body: jsonEncode({
            'choices': [
              {
                'message': {'content': reply}
              }
            ]
          }),
        );
      },
    );

const _vocab = [
  TagDimension(
      name: '画面类型', vocabulary: ['厨房情景', '产品特写', '真人口播']),
];

/// 分维度的回复：把老用例里的 {"tags":[...]} 换成按维度分格的形状
String _reply(List<String> tags, {String? description}) => jsonEncode({
      '画面类型': tags,
      'description': ?description,
    });

List<List<int>> _frames(int n) =>
    [for (var i = 0; i < n; i++) List<int>.filled(8, i)];

void main() {
  group('一次调用同时拿标签和画面描述', () {
    test('两样都解析出来', () async {
      final tagger = ShotTagger(
          chat: _chat(_reply(['厨房情景', '产品特写'],
              description: '手持喷雾在灶台上喷洒并用抹布擦拭')));

      final r = await tagger.understand(frames: _frames(3), dimensions: _vocab);

      expect(r.tags, ['厨房情景', '产品特写']);
      expect(r.description, '手持喷雾在灶台上喷洒并用抹布擦拭');
    });

    test('只有标签没有描述时不硬造一句', () async {
      final tagger = ShotTagger(chat: _chat(_reply(['厨房情景'])));

      final r = await tagger.understand(frames: _frames(2), dimensions: _vocab);

      expect(r.tags, ['厨房情景']);
      expect(r.description, isNull,
          reason: '描述是要拿去做语义检索的，编一句不如没有');
    });

    test('词表外的标签被过滤掉', () async {
      final tagger = ShotTagger(
          chat: _chat(_reply(['厨房情景', '自己编的标签'], description: 'x')));

      final r = await tagger.understand(frames: _frames(1), dimensions: _vocab);

      expect(r.tags, ['厨房情景'],
          reason: '受控词表是硬约束，模型自造的词必须在这一层挡掉');
      expect(r.tagsByDimension['画面类型'], ['厨房情景']);
    });

    test('回复带 ```json 围栏也能解析', () async {
      final tagger = ShotTagger(
          chat: _chat('```json\n${_reply(['产品特写'], description: '近景')}\n```'));

      final r = await tagger.understand(frames: _frames(1), dimensions: _vocab);

      expect(r.tags, ['产品特写']);
      expect(r.description, '近景');
    });

    test('回复完全不是 JSON 时给空结果，不抛异常', () async {
      final tagger = ShotTagger(chat: _chat('模型今天不想干活'));

      final r = await tagger.understand(frames: _frames(1), dimensions: _vocab);

      expect(r.tags, isEmpty);
      expect(r.description, isNull);
    });

    test('空描述串当作没有', () async {
      final tagger =
          ShotTagger(chat: _chat(_reply(const [], description: '   ')));

      final r = await tagger.understand(frames: _frames(1), dimensions: _vocab);

      expect(r.description, isNull);
    });
  });

  group('多帧确实被送进去了', () {
    test('送几帧就有几个 image_url', () async {
      final tagger = ShotTagger(chat: _chat(_reply(const [])));

      await tagger.understand(frames: _frames(4), dimensions: _vocab);

      final count = RegExp('"type":"image_url"').allMatches(lastBody).length;
      expect(count, 4,
          reason: '单帧只能看到一个静止姿态，判不出镜头里在发生什么——'
              '实测 3 帧能给出「转身依次指向不同货位」，单帧只有「在直播带货」');
    });

    test('没有帧时不发请求', () async {
      var called = false;
      final tagger = ShotTagger(
          chat: ArkChatClient(
              apiKey: 'x',
              post: (_, _, _) async {
                called = true;
                return const JsonPostResult(statusCode: 200, body: '{}');
              }));

      final r = await tagger.understand(frames: const [], dimensions: _vocab);

      expect(called, isFalse);
      expect(r.tags, isEmpty);
    });

    test('词表为空时仍然要画面描述——描述不依赖词表', () async {
      final tagger =
          ShotTagger(chat: _chat(_reply(const [], description: '厨房台面特写')));

      final r = await tagger.understand(frames: _frames(2), dimensions: const []);

      expect(r.description, '厨房台面特写',
          reason: '没选标签组也该拿到画面描述——阶段②的语义检索要靠它');
    });
  });

  group('提示词里要说清帧的时序', () {
    test('告诉模型这是同一镜头的连续采样', () async {
      final tagger = ShotTagger(chat: _chat(_reply(const [])));

      await tagger.understand(frames: _frames(3), dimensions: _vocab);

      expect(lastBody, contains('同一个'));
      expect(lastBody, anyOf(contains('连续'), contains('先后')),
          reason: '不说明是同一镜头的连续帧，模型会当成几张无关的图分别描述');
    });
  });
}
