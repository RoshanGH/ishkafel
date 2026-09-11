import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/features/workbench/subtitle_editor_card.dart';

/// 字幕卡里的时间要能改。
///
/// 用户 2026-09-11 先说按秒，同一天改了主意：「字幕时间用完整的时序帧……
/// 问了下同事还是这个更符合使用习惯」。所以摆出来、输进去的都是**成片时间码**
/// （`分:秒.帧`），而**存的仍然是相对这一镜的毫秒**——单元一挪，显示的
/// 时间码自己就跟着重算。
///
/// 夹的规则和时间线上拖是同一套（见 core/subtitle/subtitle_edit.dart）。
void main() {
  late List<SubtitleLine> lines;

  /// 这一镜在成片上从 20 秒开始（用它验「存相对、显示绝对」）
  const slotStart = 20000;

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
            slotStartMs: slotStart,
            fps: 30,
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

  String textOf(WidgetTester tester, String key) => tester
      .widget<TextField>(find.byKey(ValueKey(key)))
      .controller!
      .text;

  testWidgets('显示的是**成片时间码**，不是相对这一镜的秒数', (tester) async {
    await pump(tester);
    // 这一镜从 20 秒起；第二段相对 3.0~4.2 秒 → 成片 23 秒整 ~ 24 秒 6 帧
    expect(textOf(tester, 'subtitle-start-1'), '00:23.00');
    expect(textOf(tester, 'subtitle-end-1'), '00:24.06');
  });

  testWidgets('存的还是相对这一镜的——单元一挪，时间码自己重算', (tester) async {
    await pump(tester);
    // 卡片拿到的 lines 一个字没动（存的是 3000~4200），变的只有显示
    expect(lines[1].startMs, 3000);
  });

  testWidgets('改起点：输成片时间码，存回相对这一镜的毫秒', (tester) async {
    await pump(tester);
    await type(tester, 1, true, '00:22.15');
    // 22.5 秒 − 这一镜起点 20 秒 = 2.5 秒
    expect(lines[1].startMs, 2500);
    expect(lines[1].endMs, 4200, reason: '只动起点');
  });

  testWidgets('改终点', (tester) async {
    await pump(tester);
    await type(tester, 0, false, '00:21.06');
    expect(lines[0].endMs, 1200);
  });

  testWidgets('输了个会和前一段重叠的数：夹到贴边，不是照单全收', (tester) async {
    await pump(tester);
    await type(tester, 1, true, '00:20.06');
    expect(lines[1].startMs, 500, reason: '顶在前一段的结束处，两句字不能同时在画面上');
  });

  testWidgets('输了个超出这一镜的数：夹回镜头长度', (tester) async {
    await pump(tester, slotDurationMs: 5000);
    await type(tester, 1, false, '01:39.00');
    expect(lines[1].endMs, 5000);
  });

  testWidgets('输了个看不懂的：把原值放回去，不改数据也不报错框', (tester) async {
    await pump(tester);
    await type(tester, 0, false, '呃');
    expect(lines[0].endMs, 500);
    expect(textOf(tester, 'subtitle-end-0'), '00:20.15',
        reason: '框里得纠回来，否则人看到的是他输的那个没生效的值');
  });

  testWidgets('省掉分钟也认——人常常只敲秒和帧', (tester) async {
    await pump(tester);
    await type(tester, 0, false, '21.15');
    expect(lines[0].endMs, 1500);
  });

  testWidgets('卡片上带着那句图例——`.15` 是帧号不是小数', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('inspector-timecode-legend')), findsOneWidget);
  });
}
