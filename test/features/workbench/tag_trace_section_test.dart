import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/tag_trace.dart';
import 'package:ishkafel/features/workbench/tag_trace_section.dart';

Future<void> _pump(
  WidgetTester tester, {
  required List<String> tags,
  bool stale = false,
  String? description,
  TagTrace? trace,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 300,
        height: 800,
        child: SingleChildScrollView(
          child: TagTraceSection(
            title: '镜头标签',
            tags: tags,
            tagsStale: stale,
            description: description,
            trace: trace,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

TagTrace _trace() => TagTrace(
      sampledAtMs: const [1000, 2000, 3000],
      framePaths: const ['/w/a_0.jpg', '/w/a_1.jpg', '/w/a_2.jpg'],
      vocabularyGroups: const ['植源分子库', '视觉镜头库'],
      vocabularySize: 128,
      rawReply: '{"tags":["近景"],"description":"厨房台面特写"}',
      at: DateTime.utc(2026, 8, 3, 10, 30),
    );

void main() {
  group('结果', () {
    testWidgets('显示标签', (tester) async {
      await _pump(tester, tags: ['近景', '产品特写']);

      expect(find.text('近景'), findsOneWidget);
      expect(find.text('产品特写'), findsOneWidget);
    });

    testWidgets('没有标签时说清是「还没打」，不是留一片空白', (tester) async {
      await _pump(tester, tags: const []);

      expect(find.textContaining('未打标'), findsOneWidget);
    });

    testWidgets('标签过期时给出显式提示，而不是把旧标签当新的展示',
        (tester) async {
      await _pump(tester, tags: ['近景'], stale: true);

      expect(find.byKey(const Key('trace-stale-badge')), findsOneWidget);
      expect(find.text('近景'), findsOneWidget,
          reason: '过期不等于删掉——重打完成前旧标签仍是当前所知的全部');
    });

    testWidgets('有画面描述就显示出来（它是画面检索的检索键）', (tester) async {
      await _pump(tester, tags: ['近景'], description: '厨房台面上的喷雾瓶特写');

      expect(find.textContaining('厨房台面上的喷雾瓶特写'), findsOneWidget);
    });
  });

  group('过程量', () {
    testWidgets('默认收起，不占版面', (tester) async {
      await _pump(tester, tags: ['近景'], trace: _trace());

      expect(find.byKey(const Key('trace-expand')), findsOneWidget);
      expect(find.textContaining('植源分子库'), findsNothing,
          reason: '过程量是排障时才看的，默认摊开会把真正要看的属性挤下去');
    });

    testWidgets('展开后能看到喂了什么、模型原样回了什么', (tester) async {
      await _pump(tester, tags: ['近景'], trace: _trace());

      await tester.tap(find.byKey(const Key('trace-expand')));
      await tester.pumpAndSettle();

      expect(find.textContaining('3 帧'), findsOneWidget,
          reason: '采了几帧决定了模型看得见什么');
      expect(find.textContaining('植源分子库'), findsOneWidget);
      expect(find.textContaining('128'), findsOneWidget,
          reason: '词表多大直接决定标签能选到什么');
      expect(find.textContaining('"tags":["近景"]'), findsOneWidget,
          reason: '原样回复是唯一能区分「数据没取对」和「模型理解错了」的东西');
    });

    testWidgets('没有过程量时不给一个点开是空的入口', (tester) async {
      await _pump(tester, tags: ['近景']);

      expect(find.byKey(const Key('trace-expand')), findsNothing);
    });

    testWidgets('台词层的过程量显示喂进去的台词，不显示采样帧',
        (tester) async {
      await _pump(
        tester,
        tags: ['促销'],
        trace: const TagTrace(
          textInput: '再不买就恢复六十九块九一瓶了',
          vocabularyGroups: ['台词库'],
          vocabularySize: 40,
          rawReply: '{"tags":["促销"]}',
        ),
      );

      await tester.tap(find.byKey(const Key('trace-expand')));
      await tester.pumpAndSettle();

      expect(find.textContaining('再不买就恢复六十九块九一瓶了'), findsOneWidget);
      expect(find.textContaining('帧'), findsNothing,
          reason: '台词层没有采样帧，显示「0 帧」会让人以为抽帧失败了');
    });
  });
}
