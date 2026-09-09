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
  _byDimension();

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

/// 分维度展示：一个镜头同时有四个维度的标签时，堆成一排就看不出
/// 「场景判成了什么、动作判成了什么」
void _byDimension() {
  testWidgets('标签按维度分行显示', (tester) async {
    await _pump(
      tester,
      tags: ['厨房情景', '打开电器'],
      trace: const TagTrace(
        vocabularyGroups: ['植源场景', '植源动作'],
        vocabularySize: 40,
        tagsByDimension: {
          '植源场景': ['厨房情景'],
          '植源动作': ['打开电器'],
        },
      ),
    );

    expect(find.text('植源场景'), findsOneWidget);
    expect(find.text('植源动作'), findsOneWidget);
    expect(find.text('厨房情景'), findsOneWidget);
  });

  testWidgets('某个维度一个都没打上时显式写出来', (tester) async {
    await _pump(
      tester,
      tags: ['厨房情景'],
      trace: const TagTrace(
        tagsByDimension: {
          '植源场景': ['厨房情景'],
          '植源动作': [],
        },
      ),
    );

    expect(find.text('—'), findsOneWidget,
        reason: '不显示的话用户会以为这个维度压根没送进去');
  });

  /// 2026-09-09 真机，用户截图标注：「改完以后这里不变化」。
  ///
  /// 「改标签」写的是 shot.tags，而属性栏当时画的是 trace.tagsByDimension
  /// ——那是打标那一刻模型的原始回答，手改一个字都不会动它。于是删到只剩
  /// 一个，界面照旧摆着原来四个。
  group('手改标签之后，分维度显示要跟着变', () {
    const trace = TagTrace(
      tagsByDimension: {
        '植源场景': ['厨房情景', '客厅情景'],
        '植源动作': ['打开电器'],
      },
    );

    testWidgets('删掉的标签不再显示', (tester) async {
      await _pump(tester, tags: ['厨房情景'], trace: trace);

      expect(find.text('厨房情景'), findsOneWidget);
      expect(find.text('客厅情景'), findsNothing,
          reason: '人已经把它删了，属性栏还摆着就是「改完不变化」');
      expect(find.text('打开电器'), findsNothing);
    });

    testWidgets('维度被删空了照旧留着这一行，写成「—」', (tester) async {
      await _pump(tester, tags: ['厨房情景'], trace: trace);

      expect(find.text('植源动作'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('人手加的标签一个都不能吞', (tester) async {
      await _pump(tester, tags: ['厨房情景', '手加的一个'], trace: trace);

      expect(find.text('手加的一个'), findsOneWidget,
          reason: '维度表里没有它，归到「其他」也要露出来');
      expect(find.text('其他'), findsOneWidget);
    });

    testWidgets('模型打的一个都没留下：退回一排，不摆空骨架', (tester) async {
      await _pump(tester, tags: ['全换成手选的'], trace: trace);

      expect(find.text('全换成手选的'), findsOneWidget);
      expect(find.text('植源场景'), findsNothing);
      expect(find.text('—'), findsNothing);
    });
  });

  testWidgets('展开过程量能看到这一层的约束', (tester) async {
    await _pump(
      tester,
      tags: ['厨房情景'],
      trace: const TagTrace(
        vocabularyGroups: ['植源场景'],
        vocabularySize: 20,
        prompt: '只判断主体所处的空间',
        rawReply: '{}',
      ),
    );

    await tester.tap(find.byKey(const Key('trace-expand')));
    await tester.pumpAndSettle();

    expect(find.textContaining('只判断主体所处的空间'), findsOneWidget,
        reason: '标签不对时，「喂进去的约束是什么」往往才是问题所在');
  });

  testWidgets('旧数据没有维度信息时退回一排 chips，不崩', (tester) async {
    await _pump(tester, tags: ['近景', '中景']);

    expect(find.text('近景'), findsOneWidget);
    expect(find.text('中景'), findsOneWidget);
  });
}
