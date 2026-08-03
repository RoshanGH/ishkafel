import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';

const _dims = [
  TagDimension(
      name: '植源场景', vocabulary: ['厨房情景', '客厅情景'], prompt: '只看主体所处的空间'),
  TagDimension(name: '植源动作', vocabulary: ['打开电器', '喷洒'], prompt: null),
];

void main() {
  group('提示词把维度分开写，而不是把词表一股脑混在一起', () {
    test('每个维度各自成段，带自己的词表', () {
      final text = buildDimensionPrompt(_dims);

      expect(text, contains('植源场景'));
      expect(text, contains('植源动作'));
      expect(text.indexOf('植源场景'), lessThan(text.indexOf('植源动作')),
          reason: '顺序要跟用户选组的顺序一致，便于对照');
      expect(text, contains('厨房情景'));
      expect(text, contains('打开电器'));
    });

    test('维度自带的约束跟在它自己那一段后面', () {
      final text = buildDimensionPrompt(_dims);

      final sceneAt = text.indexOf('植源场景');
      final constraintAt = text.indexOf('只看主体所处的空间');
      final actionAt = text.indexOf('植源动作');

      expect(constraintAt, greaterThan(sceneAt));
      expect(constraintAt, lessThan(actionAt),
          reason: '约束落到别的维度下面，等于给错了指令');
    });

    test('没写约束的维度不留一个空的「约束：」', () {
      final text = buildDimensionPrompt([_dims[1]]);

      expect(text, isNot(contains('约束：\n')));
      expect(text, isNot(contains('约束：null')));
    });

    test('要求按维度名分开输出，而不是一个扁平数组', () {
      final text = buildDimensionPrompt(_dims);

      expect(text, contains('"植源场景"'));
      expect(text, contains('"植源动作"'));
    });
  });

  group('解析：按维度收，各自用各自的词表过滤', () {
    test('分维度返回，且各维度只留自己词表里的词', () {
      final parsed = parseDimensionTags(
        jsonEncode({
          '植源场景': ['厨房情景', '打开电器'], // 「打开电器」不属于这个维度
          '植源动作': ['打开电器'],
        }),
        _dims,
      );

      expect(parsed.byDimension['植源场景'], ['厨房情景'],
          reason: '串味的词必须挡掉——否则「维度分开」只是提示词上说说而已');
      expect(parsed.byDimension['植源动作'], ['打开电器']);
    });

    test('扁平标签按维度顺序拼出来，供检索与展示', () {
      final parsed = parseDimensionTags(
        jsonEncode({
          '植源动作': ['喷洒'],
          '植源场景': ['客厅情景'],
        }),
        _dims,
      );

      expect(parsed.flatTags, ['客厅情景', '喷洒'],
          reason: '按用户选组的顺序，不是按模型回复的顺序');
    });

    test('模型漏答某个维度时那个维度为空，其余照常', () {
      final parsed = parseDimensionTags(
        jsonEncode({'植源场景': ['厨房情景']}),
        _dims,
      );

      expect(parsed.byDimension['植源动作'], isEmpty);
      expect(parsed.flatTags, ['厨房情景']);
    });

    test('回复被 ``` 包起来照样解析（模型常这么干）', () {
      final parsed = parseDimensionTags(
        '```json\n{"植源场景":["厨房情景"]}\n```',
        _dims,
      );

      expect(parsed.flatTags, ['厨房情景']);
    });

    test('回复不是 JSON 时返回空，而不是抛异常打断整批打标', () {
      final parsed = parseDimensionTags('模型今天不想输出 JSON', _dims);

      expect(parsed.flatTags, isEmpty);
      expect(parsed.byDimension.keys, ['植源场景', '植源动作'],
          reason: '维度键要在，界面上才能显示「这个维度没打上」');
    });

    test('同一个词在两个维度都合法时各自都留（不去重成一个）', () {
      const shared = [
        TagDimension(name: 'A', vocabulary: ['实拍'], prompt: null),
        TagDimension(name: 'B', vocabulary: ['实拍'], prompt: null),
      ];

      final parsed = parseDimensionTags(
        jsonEncode({'A': ['实拍'], 'B': ['实拍']}),
        shared,
      );

      expect(parsed.byDimension['A'], ['实拍']);
      expect(parsed.byDimension['B'], ['实拍']);
      expect(parsed.flatTags, ['实拍'],
          reason: '扁平列表是给检索用的，同一个标签重复两遍只会让检索键变脏');
    });
  });
}
