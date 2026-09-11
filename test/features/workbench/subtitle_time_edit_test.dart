import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/features/workbench/subtitle_editor_card.dart';

/// 字幕卡里的时间要能改。
///
/// 用户 2026-09-11：「前面的时间我也要编辑……按照秒数也行，就按现在的秒数，
/// 并且是相对于这个镜头的秒数。」
///
/// 夹的规则和时间线上拖是同一套（见 core/subtitle/subtitle_edit.dart）。
void main() {
  late List<SubtitleLine> lines;

  Future<void> pump(WidgetTester tester, {int slotDurationMs = 5000}) async {
    lines = const [
      SubtitleLine(startMs: 0, endMs: 500, text: '看看啊'),
      SubtitleLine(startMs: 3000, endMs: 4200, text: '哇这也太猛了'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SubtitleEditorCard(
            replaced: true,
            lines: lines,
            edited: true,
            slotDurationMs: slotDurationMs,
            onChanged: (v) => setState(() => lines = v),
            onResetToAuto: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 在第 [i] 段的起/止格里输入，然后把焦点挪走（离开才提交）
  Future<void> type(WidgetTester tester, int i, bool start, String v) async {
    final key = ValueKey('subtitle-${start ? 'start' : 'end'}-$i');
    await tester.enterText(find.byKey(key), v);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('subtitle-text-0')));
    await tester.pumpAndSettle();
  }

  testWidgets('时间是可编辑的格子，显示的是相对这一镜的秒数', (tester) async {
    await pump(tester);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('subtitle-start-1')))
            .controller!
            .text,
        '3.0');
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('subtitle-end-1')))
            .controller!
            .text,
        '4.2');
  });

  testWidgets('改起点：离开格子才提交', (tester) async {
    await pump(tester);
    await type(tester, 1, true, '2.5');
    expect(lines[1].startMs, 2500);
    expect(lines[1].endMs, 4200, reason: '只动起点');
  });

  testWidgets('改终点', (tester) async {
    await pump(tester);
    await type(tester, 0, false, '1.2');
    expect(lines[0].endMs, 1200);
  });

  testWidgets('输了个会和前一段重叠的数：夹到贴边，不是照单全收', (tester) async {
    await pump(tester);
    await type(tester, 1, true, '0.2');
    expect(lines[1].startMs, 500, reason: '顶在前一段的结束处，两句字不能同时在画面上');
  });

  testWidgets('输了个超出这一镜的数：夹回镜头长度', (tester) async {
    await pump(tester, slotDurationMs: 5000);
    await type(tester, 1, false, '99');
    expect(lines[1].endMs, 5000);
  });

  testWidgets('输了个看不懂的：把原值放回去，不改数据也不报错框', (tester) async {
    await pump(tester);
    await type(tester, 0, false, '呃');
    expect(lines[0].endMs, 500);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('subtitle-end-0')))
            .controller!
            .text,
        '0.5',
        reason: '框里得纠回来，否则人看到的是他输的那个没生效的值');
  });

  testWidgets('带个 s 也认——显示上没有单位，但人会顺手打出来', (tester) async {
    await pump(tester);
    await type(tester, 0, false, '1.5s');
    expect(lines[0].endMs, 1500);
  });
}
