import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/external_steps.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// AI 步骤外包给调用方。
///
/// **外包出去的是判断，不是数据结构的定义权**：它可以决定「这几句归一组」
/// 「这个镜头贴什么标签」，但不能改台词内容、不能漏掉句子、不能用词表外的词。
void main() {
  group('哪些能外包', () {
    test('只有输出可验证的那几步', () {
      expect(externalStepFrom('segment'), ExternalStep.segment);
      expect(externalStepFrom('tag'), ExternalStep.tag);
      expect(externalStepFrom('tags'), ExternalStep.tag);
    });

    test('ASR 不在清单里——它的时间戳没法验证', () {
      expect(externalStepFrom('asr'), isNull);
      expect(externalStepFrom('transcribe'), isNull);
    });

    test('认不出的名字要报出来，不能静默忽略', () {
      // 静默忽略会让调用方以为外包生效了，其实还在烧内置 API
      final parsed = parseExternal('segment,asr,乱写');
      expect(parsed.steps, {ExternalStep.segment});
      expect(parsed.unknown, ['asr', '乱写']);
    });

    test('空值就是全部走内置', () {
      expect(parseExternal(null).steps, isEmpty);
      expect(parseExternal('').steps, isEmpty);
    });
  });

  group('回填切分', () {
    final sentences = [
      const AsrSentence(startMs: 0, endMs: 1000, text: '第一句。'),
      const AsrSentence(startMs: 1000, endMs: 2000, text: '第二句。'),
      const AsrSentence(startMs: 2000, endMs: 3000, text: '第三句。'),
    ];

    ({List errors, List drafts}) parse(String json) {
      final r = parseSegments(jsonDecode(json), sentences);
      return (errors: r.errors, drafts: r.drafts);
    }

    test('按句子下标分组，台词由句子拼出来', () {
      final r = parse('{"units":[{"fromSentence":0,"toSentence":1},'
          '{"fromSentence":2,"toSentence":2}]}');
      expect(r.errors, isEmpty);
      expect(r.drafts, hasLength(2));
      expect(r.drafts.first.transcript, '第一句。第二句。');
      expect(r.drafts.first.startMs, 0);
      expect(r.drafts.first.endMs, 2000);
    });

    test('漏掉句子要挡住——那会让台词与画面错位', () {
      final r = parse('{"units":[{"fromSentence":0,"toSentence":0}]}');
      expect(r.errors.single, contains('还有 2 句没有归入'));
    });

    test('不连续要挡住', () {
      final r = parse('{"units":[{"fromSentence":0,"toSentence":0},'
          '{"fromSentence":2,"toSentence":2}]}');
      expect(r.errors.first, contains('应该从第 1 句开始'));
    });

    test('越界要挡住', () {
      final r = parse('{"units":[{"fromSentence":0,"toSentence":9}]}');
      expect(r.errors.single, contains('越界'));
    });

    test('台词内容不收调用方的——那是 ASR 的产出', () {
      final r = parse('{"units":[{"fromSentence":0,"toSentence":2,'
          '"transcript":"我自己编的台词"}]}');
      expect(r.errors, isEmpty);
      expect(r.drafts.single.transcript, '第一句。第二句。第三句。');
    });

    test('空数组、非对象都挡住', () {
      expect(parse('{"units":[]}').errors, isNotEmpty);
      expect(parseSegments('不是对象', sentences).errors, isNotEmpty);
    });
  });

  group('回填标签', () {
    final units = [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: 'A',
        shots: const [Shot(startMs: 0, endMs: 2000)],
      ),
    ];

    ({List<SemanticUnit> units, List<String> errors}) parse(String json) =>
        parseTags(
          jsonDecode(json),
          units,
          unitVocabulary: {'促单', '痛点'},
          shotVocabulary: {'厨房情景'},
        );

    test('词表内的收下', () {
      final r = parse('{"units":[{"unit":0,"tags":["促单"],'
          '"shots":{"0":["厨房情景"]}}]}');
      expect(r.errors, isEmpty);
      expect(r.units.single.tags, ['促单']);
      expect(r.units.single.shots.single.tags, ['厨房情景']);
      expect(r.units.single.tagsStale, isFalse);
    });

    test('词表外的一律拒绝，不做近似匹配', () {
      // 「厨房场景」和「厨房情景」在检索时是两回事
      final r = parse('{"units":[{"unit":0,"shots":{"0":["厨房场景"]}}]}');
      expect(r.errors.single, contains('不在受控词表里'));
    });

    test('单元层用错词表也拒绝', () {
      final r = parse('{"units":[{"unit":0,"tags":["厨房情景"]}]}');
      expect(r.errors.single, contains('不在受控词表里'));
    });

    test('不存在的单元/镜头挡住', () {
      expect(parse('{"units":[{"unit":9}]}').errors.single,
          contains('不存在的单元'));
      expect(parse('{"units":[{"unit":0,"shots":{"5":[]}}]}').errors.single,
          contains('不存在的镜头'));
    });

    test('有任何一条不合格就整批不落——不能对一半错一半', () {
      final r = parse('{"units":[{"unit":0,"tags":["促单","编的"]}]}');
      expect(r.errors, isNotEmpty);
      expect(r.units.single.tags, isEmpty, reason: '原样退回，不落一半');
    });
  });
}
