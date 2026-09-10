import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/shared/scroll_fade.dart';

/// **内容没到底，就得让人看出来还有。**
///
/// 2026-09-09 设计走查：属性面板里「单元台词（可编辑）」和「拆分 / 并入」
/// 落在可视区外，而 macOS 的滚动条是 overlay 式的，不动鼠标根本不出现——
/// 人看不到那两样东西，也没有任何线索说下面还有。
void main() {
  Widget wrap({required double contentHeight, required double boxHeight}) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: boxHeight,
              width: 200,
              child: ScrollFade(
                background: const Color(0xFF232326),
                child: ListView(
                  children: [SizedBox(height: contentHeight)],
                ),
              ),
            ),
          ),
        ),
      );

  int fadeCount(WidgetTester tester) =>
      tester.widgetList(find.byKey(scrollFadeKey)).length;

  testWidgets('内容比框高：下沿压一层淡出', (tester) async {
    await tester.pumpWidget(wrap(contentHeight: 900, boxHeight: 200));
    await tester.pumpAndSettle();

    expect(fadeCount(tester), 1, reason: '下面还有内容却什么都不提示');
  });

  testWidgets('内容装得下：不摆多余的一层', (tester) async {
    await tester.pumpWidget(wrap(contentHeight: 50, boxHeight: 200));
    await tester.pumpAndSettle();

    expect(fadeCount(tester), 0, reason: '没东西可滚还渐隐，看着像脏了一条边');
  });

  testWidgets('滚到底之后淡出撤掉', (tester) async {
    await tester.pumpWidget(wrap(contentHeight: 400, boxHeight: 200));
    await tester.pumpAndSettle();
    expect(fadeCount(tester), 1);

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(fadeCount(tester), 0, reason: '已经到底了还提示「还有」是在骗人');
  });
}
