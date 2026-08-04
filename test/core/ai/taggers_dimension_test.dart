import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/net/json_poster.dart';

const _dims = [
  TagDimension(
      name: '植源场景', vocabulary: ['厨房情景', '客厅情景']),
  TagDimension(name: '植源动作', vocabulary: ['打开电器', '喷洒']),
];

/// 记录发出去的请求体，并按脚本返回内容
ArkChatClient _client(String reply, {List<String>? sentBodies}) => ArkChatClient(
      apiKey: 'x',
      post: (_, _, body) async {
        sentBodies?.add(body);
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

void main() {
  group('视觉镜头打标：分维度问、分维度收', () {
    test('提示词里带上每个维度的词表，以及这一层那一条约束', () async {
      final bodies = <String>[];
      await ShotTagger(chat: _client('{}', sentBodies: bodies)).understand(
        frames: [
          [1],
          [2],
          [3]
        ],
        dimensions: _dims,
        constraint: '只看主体所处的空间',
      );

      final sent = bodies.single;
      expect(sent, contains('植源场景'));
      expect(sent, contains('植源动作'));
      expect(sent, contains('只看主体所处的空间'));
      expect(sent, contains('3 张图'),
          reason: '不说明「这几张是同一镜头的连续采样」，模型会把它们当成'
              '几张无关的图分别描述');
    });

    test('只调用一次——分维度不等于分多次', () async {
      final bodies = <String>[];
      await ShotTagger(chat: _client('{}', sentBodies: bodies)).understand(
        frames: [
          [1]
        ],
        dimensions: _dims,
      );

      expect(bodies, hasLength(1),
          reason: '拆成一个维度一次调用，会让最贵最慢的视觉推理翻四倍');
    });

    test('按维度收结果，串味的词挡掉', () async {
      final r = await ShotTagger(
              chat: _client(jsonEncode({
        '植源场景': ['厨房情景', '打开电器'],
        '植源动作': ['打开电器'],
        'description': '厨房里打开冰箱门',
      })))
          .understand(frames: [
        [1]
      ], dimensions: _dims);

      expect(r.tagsByDimension['植源场景'], ['厨房情景']);
      expect(r.tagsByDimension['植源动作'], ['打开电器']);
      expect(r.tags, ['厨房情景', '打开电器'], reason: '扁平列表按维度顺序拼');
      expect(r.description, '厨房里打开冰箱门');
    });

    test('没有维度时仍然要问——画面描述不依赖词表', () async {
      final bodies = <String>[];
      final r = await ShotTagger(
              chat: _client(jsonEncode({'description': '厨房台面特写'}),
                  sentBodies: bodies))
          .understand(frames: [
        [1]
      ], dimensions: const []);

      expect(r.tags, isEmpty);
      expect(r.description, '厨房台面特写',
          reason: '没选标签组就连描述也不给，等于把「按画面描述检索素材」'
              '这条路一起堵死');
      expect(bodies, hasLength(1));
    });

    test('没有帧时不打网络', () async {
      final bodies = <String>[];
      final r = await ShotTagger(chat: _client('{}', sentBodies: bodies))
          .understand(frames: const [], dimensions: _dims);

      expect(bodies, isEmpty, reason: '没画面可看还去问一遍，是白花钱');
      expect(r.tags, isEmpty);
    });

    test('原样回复照旧带出来，解析出错时靠它定位', () async {
      final r = await ShotTagger(chat: _client('不是 JSON')).understand(
          frames: [
            [1]
          ],
          dimensions: _dims);

      expect(r.rawReply, '不是 JSON');
      expect(r.tags, isEmpty);
    });
  });

  group('台词语义单元打标：同样分维度', () {
    test('把台词和维度都送进去', () async {
      final bodies = <String>[];
      await UnitTagger(chat: _client('{}', sentBodies: bodies)).understand(
        transcript: '再不买就恢复六十九块九一瓶了',
        dimensions: const [
          TagDimension(name: '植源分子库', vocabulary: ['促单', '痛点']),
        ],
        constraint: '按话术意图判断',
      );

      final sent = bodies.single;
      expect(sent, contains('再不买就恢复六十九块九一瓶了'));
      expect(sent, contains('植源分子库'));
      expect(sent, contains('按话术意图判断'));
    });

    test('按维度收', () async {
      final r = await UnitTagger(
              chat: _client(jsonEncode({
        '植源分子库': ['促单', '不在词表里的词'],
      })))
          .understand(transcript: '台词', dimensions: const [
        TagDimension(name: '植源分子库', vocabulary: ['促单', '痛点']),
      ]);

      expect(r.tags, ['促单']);
      expect(r.tagsByDimension['植源分子库'], ['促单']);
    });
  });
}
