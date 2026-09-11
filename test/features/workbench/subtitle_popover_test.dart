import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/features/workbench/subtitle_popover.dart';

/// 双击时间线上的字幕块，就地把这一镜的字幕改掉。
///
/// 用户 2026-09-08：「我双击那个字幕轨上的那个字幕的时候，能不能在那个地方改？」
void main() {
  late List<SubtitleLine> committed;
  late bool reset;

  Future<void> open(WidgetTester tester,
      {List<SubtitleLine> lines = const [
        SubtitleLine(startMs: 0, endMs: 800, text: '了李斯特菌'),
        SubtitleLine(startMs: 800, endMs: 1600, text: '沙门氏菌的游乐场'),
      ]}) async {
    committed = const [];
    reset = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showSubtitlePopover(
                context,
                anchor: const Rect.fromLTWH(400, 500, 80, 22),
                lines: lines,
                edited: true,
                slotDurationMs: 60000,
                onChanged: (v) => committed = v,
                onResetToAuto: () => reset = true,
              ),
              child: const Text('开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('开'));
    await tester.pumpAndSettle();
  }

  testWidgets('弹出来就是这一镜的全部字幕行，不只头一句', (tester) async {
    await open(tester);

    // 按 key 数文字框：同一行里还有两个时间格，按类型数会把它们也算进来
    expect(find.byKey(const ValueKey('subtitle-text-0')), findsOneWidget,
        reason: '轨上只画得下头一句，浮层里要能看到全部');
    expect(find.byKey(const ValueKey('subtitle-text-1')), findsOneWidget);
    expect(find.text('了李斯特菌'), findsOneWidget);
    expect(find.text('沙门氏菌的游乐场'), findsOneWidget);
  });

  testWidgets('改完离开输入框才提交——和右侧那张卡一个规矩', (tester) async {
    await open(tester);

    await tester.enterText(find.byKey(const ValueKey('subtitle-text-0')), '李斯特菌');
    await tester.pump();
    expect(committed, isEmpty, reason: '敲字的过程中不该提交');

    await tester.tap(find.byKey(const ValueKey('subtitle-text-1')));
    await tester.pumpAndSettle();

    expect(committed.first.text, '李斯特菌');
  });

  testWidgets('加一段：浮层里当场多一行，不用关掉重开', (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('subtitle-add')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('subtitle-text-2')), findsOneWidget,
        reason: '浮层拿的是打开那一刻的快照，不自己更新的话人看不到新加的行');
    expect(committed.length, 3);
  });

  testWidgets('点「改回自动」之后浮层关掉——那一镜已经没有手改的字幕了',
      (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('subtitle-reset')));
    await tester.pumpAndSettle();

    expect(reset, isTrue);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('点浮层外面就关掉', (tester) async {
    await open(tester);

    await tester.tapAt(const Offset(50, 50));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('不压暗背景——人要一边改一边看时间线上那一块在哪儿', (tester) async {
    await open(tester);

    final barrier = tester.widgetList<ModalBarrier>(find.byType(ModalBarrier));

    expect(barrier.any((b) => b.color != null && b.color!.a > 0), isFalse);
  });
}
