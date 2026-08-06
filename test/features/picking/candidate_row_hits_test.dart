import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/features/picking/candidate_card.dart';
import 'package:ishkafel/features/picking/candidate_row.dart';
import 'package:ishkafel/features/picking/candidate_search_controller.dart';

CandidateEntry _entry({required List<String> tags}) => CandidateEntry(
      material: CandidateMaterial(
        id: 7,
        name: '素材',
        sceneDescription: '灶台上喷洒清洁剂',
        thumbnailUrl: null,
        previewUrl: null,
        fileKey: null,
        tags: tags,
      ),
      probing: false,
      spec: const CandidateSpec(durationMs: 2000, width: 1080, height: 1920),
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<String> materialTags,
  required List<String> queryTags,
}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          child: CandidateRow(
            entry: _entry(tags: materialTags),
            selected: false,
            targetMs: 2000,
            onTap: () {},
            onPlay: () {},
            queryTags: queryTags,
          ),
        ),
      ),
    ));

void main() {
  testWidgets('命中的标签逐个标出来，不只给一个数字', (tester) async {
    await _pump(tester,
        materialTags: const ['灶台', '实拍', '无关的'],
        queryTags: const ['灶台', '常规清洁', '实拍', '厨房情景']);

    expect(find.byKey(const Key('candidate-hit-7-灶台')), findsOneWidget);
    expect(find.byKey(const Key('candidate-hit-7-实拍')), findsOneWidget);
    expect(find.text('2/4'), findsOneWidget,
        reason: '个数仍要保留——它解释了排序凭什么把这条排前面');
  });

  testWidgets('没命中的检索标签不列出来，免得看着像命中了', (tester) async {
    await _pump(tester,
        materialTags: const ['灶台'], queryTags: const ['灶台', '常规清洁']);

    expect(find.byKey(const Key('candidate-hit-7-常规清洁')), findsNothing);
  });

  testWidgets('一个都没命中时整块不出现，不占位', (tester) async {
    await _pump(tester,
        materialTags: const ['别的'], queryTags: const ['灶台', '实拍']);

    expect(find.textContaining('/2'), findsNothing);
  });

  testWidgets('没有检索标签时（按画面描述检索）不显示命中信息', (tester) async {
    await _pump(tester, materialTags: const ['灶台'], queryTags: const []);

    expect(find.byKey(const Key('candidate-hit-7-灶台')), findsNothing);
  });

  testWidgets('标签多到一行放不下也不撑破布局', (tester) async {
    await _pump(tester,
        materialTags: const ['灶台', '实拍', '口播', '厨房情景', '常规清洁', '人物喷'],
        queryTags: const ['灶台', '实拍', '口播', '厨房情景', '常规清洁', '人物喷']);

    expect(tester.takeException(), isNull,
        reason: '这一行高度固定，溢出会直接画出黄黑条');
    expect(find.byKey(const Key('candidate-hit-7-人物喷')), findsOneWidget);
  });

  group('镜头替换用的是画面卡片，那里也要标出来', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      required List<String> materialTags,
      required List<String> queryTags,
    }) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 112,
                height: 174,
                child: CandidateCard(
                  entry: _entry(tags: materialTags),
                  selected: false,
                  targetMs: 2000,
                  onTap: () {},
                  onPlay: () {},
                  queryTags: queryTags,
                ),
              ),
            ),
          ),
        ));

    testWidgets('卡片上写出命中了哪几个', (tester) async {
      await pumpCard(tester,
          materialTags: const ['灶台', '实拍'],
          queryTags: const ['灶台', '常规清洁', '实拍']);

      final text =
          tester.widget<Text>(find.byKey(const Key('picking-hits-7'))).data!;
      expect(text, contains('灶台'));
      expect(text, contains('实拍'));
      expect(text, startsWith('2/3'));
    });

    testWidgets('一个都没命中时不占位', (tester) async {
      await pumpCard(tester,
          materialTags: const ['别的'], queryTags: const ['灶台']);

      expect(find.byKey(const Key('picking-hits-7')), findsNothing);
    });

    testWidgets('标签多到放不下也不撑破格子', (tester) async {
      await pumpCard(tester,
          materialTags: const ['灶台', '实拍', '口播', '厨房情景', '常规清洁'],
          queryTags: const ['灶台', '实拍', '口播', '厨房情景', '常规清洁']);

      expect(tester.takeException(), isNull,
          reason: '格子只有 112pt 宽，溢出会直接画出黄黑条');
    });
  });
}
