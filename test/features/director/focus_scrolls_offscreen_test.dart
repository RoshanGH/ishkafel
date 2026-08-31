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
