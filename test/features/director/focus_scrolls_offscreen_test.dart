import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/director/scroll_into_view.dart';

/// 可视模式下 Agent 一行行往下做，界面要跟着走到那一行。
///
/// 右栏一屏只放得下三四行卡片，而 `ListView` 是**懒构建**的：焦点落到
/// 第 11 行时那一行的 widget 压根还没创建，靠 `didUpdateWidget` 触发的
/// 滚动因此永远不会发生——**Agent 一过第 4 行，界面就再也不动了**。
///
/// 人看到的是：播报条一直说着「正在给第 11 行找镜头」，画面停在第 1 行
/// 纹丝不动。可视模式于是退化成一条日志，而它本该是这个软件最值钱的部分。
void main() {
  mainStable();
  group('粗滚：把没构建的那一行带进视口', () {
    test('等分估落点', () {
      expect(
          estimateOffsetFor(index: 0, count: 25, maxExtent: 2400), 0);
      expect(estimateOffsetFor(index: 24, count: 25, maxExtent: 2400), 2400);
      expect(estimateOffsetFor(index: 12, count: 25, maxExtent: 2400), 1200);
    });

    test('只有一行、或者根本滚不动：不要算出个 NaN 来', () {
      expect(estimateOffsetFor(index: 0, count: 1, maxExtent: 0), 0);
      expect(estimateOffsetFor(index: 3, count: 4, maxExtent: 0), 0);
    });

    testWidgets('焦点在视口外：真的滚过去', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: ListView.builder(
              controller: controller,
              itemCount: 25,
              itemBuilder: (context, i) =>
                  SizedBox(height: 100, child: Text('第 $i 行')),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(controller.offset, 0);

      ensureIndexVisible(controller: controller, index: 11, count: 25);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(controller.offset, greaterThan(0),
          reason: 'Agent 说它在做第 11 行，界面却停在第 1 行——'
              '可视模式就只剩一条播报了');
    });

    testWidgets('那一行已经在眼前：不要再跳一下', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: ListView.builder(
              controller: controller,
              itemCount: 25,
              itemBuilder: (context, i) =>
                  SizedBox(height: 100, child: Text('第 $i 行')),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      ensureIndexVisible(controller: controller, index: 0, count: 25);
      await tester.pumpAndSettle();
      expect(controller.offset, 0, reason: '本来就在眼前，白跳一下只会晃眼');
    });
  });

  group('精调：刚被建出来就已经是焦点', () {
    testWidgets('initState 那一半也要能滚——不能只认 didUpdateWidget',
        (tester) async {
      final controller = ScrollController();
      // 所有行一开始就在树上（模拟粗滚之后：目标行已经建出来了），
      // 焦点一上来就落在第 8 行——这一下走的是 initState，不是 didUpdateWidget
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: SingleChildScrollView(
              controller: controller,
              child: Column(
                children: [
                  for (var i = 0; i < 25; i++)
                    ScrollIntoView(
                      active: i == 8,
                      child: SizedBox(height: 100, child: Text('第 $i 行')),
                    ),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(controller.offset, greaterThan(0),
          reason: '粗滚把那一行带进来之后，它得自己对齐到眼前；'
              '只认 didUpdateWidget 的话这一下会漏掉');
    });
  });

  group('正在被操作的那一行要看得出来', () {
    test('Agent 的焦点行有专门的强调，不跟人自己选中混在一起', () {
      final src = File('lib/features/director/line_board.dart').readAsStringSync();
      expect(src, contains('agentFocused'),
          reason: '可视模式的全部意义就是让人一眼看出它在动哪一行；'
              '和普通选中长一个样的话，人得盯着播报条读字才知道');
      expect(src, contains('boxShadow'),
          reason: '滚过来的同时要有发光把人眼带过去');
      expect(src, contains('agentFocused: focusLineIndex == i'),
          reason: '光有样式没接上焦点，等于没有');
    });
  });
}

/// **同一行上不许反复滚。**
///
/// Agent 在一行上会连着播好几条（找镜头 → 看参考片画面 → 搜到候选 →
/// 提交），焦点一直是这一行、只有动作在变。此前每一条都触发一次「粗滚」，
/// 而粗滚按平均行高估位置——行高其实差得远（一行可能挂着 9 个镜头卡片），
/// 估出来的落点比真实位置偏上一大截。于是精调刚把这一行对准，下一条播报
/// 又把画面拽回估算点，来回弹。
///
/// 产品负责人看到的：「它会不停地从这一行跳到第一行，不能稳定地像人的操作
/// 一样稳定在它操作的这一行上。」判据是：**Agent 从第 1 行做到第 27 行，
/// 界面应该往下走 27 次，不是上下弹一百次。**
void mainStable() {
  group('稳定停在它操作的那一行', () {
    testWidgets('那一行已经构建出来了：粗滚不出手，交给精调', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: ListView.builder(
              controller: controller,
              itemCount: 25,
              itemBuilder: (context, i) =>
                  SizedBox(height: 100, child: Text('第 $i 行')),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // 精调已经把第 8 行摆到了眼前（真实位置，比等分估算靠下）
      controller.jumpTo(760);
      await tester.pumpAndSettle();

      ensureIndexVisible(
          controller: controller, index: 8, count: 25, alreadyBuilt: true);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(controller.offset, 760,
          reason: '这一行已经在树上，粗滚的活儿早干完了——'
              '再按估算滚一次只会把对准的画面拽回去');
    });


    test('编导台真的只在换行时滚——不是光有能力没接上', () {
      final src =
          File('lib/features/director/director_page.dart').readAsStringSync();
      expect(src, contains('_scrolledTo != focus.lineIndex'),
          reason: '同一行上的后续播报再滚一次，就会把精调对准的画面拽回估算点');
      expect(src, contains('alreadyBuilt: _builtRows.has'),
          reason: '已经在树上的行由它自己精确对齐，粗滚不该插手');
      expect(src, contains('_scrolledTo = null'),
          reason: 'Agent 走了要清掉，下次回来重新对齐一次');
    });

    test('没构建出来的行，粗滚照旧出手', () {
      // alreadyBuilt 为 false 时行为不变：把它带进构建范围是粗滚的唯一职责
      expect(estimateOffsetFor(index: 12, count: 25, maxExtent: 2400), 1200);
    });
  });
}
