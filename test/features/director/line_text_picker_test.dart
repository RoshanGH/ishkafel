import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/features/director/line_text_picker.dart';

/// 台词上划词：选中几个字 → 「用这几个字加分镜」。
///
/// 已经被某一镜占住的字**根本划不了**——选中它不会出现按钮。人不做无效
/// 操作，比做完了再被拒绝好；想改就删掉那一镜，那几个字自动恢复可划。
void main() {
  const src = '如果你觉得有点贵，那就趁现在活动赶紧买';
  final words = [
    for (final t in ['如果', '你', '觉得', '有点', '贵', '那就', '趁现在', '活动', '赶紧', '买'])
      VoiceWord(text: t, startMs: 0, endMs: 100),
  ];

  Future<void> pump(
    WidgetTester tester, {
    List<({int start, int end})> taken = const [],
    void Function(int start, int end)? onPick,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LineTextPicker(
            text: src,
            words: words,
            takenWordRanges: taken,
            onPick: onPick ?? (_, __) {},
          ),
        ),
      ));

  testWidgets('台词照常显示出来', (tester) async {
    await pump(tester);
    expect(find.textContaining('如果你觉得有点贵'), findsOneWidget);
  });

  testWidgets('没选中任何字时，不出现「加分镜」', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('pick-add-shot')), findsNothing);
  });

  testWidgets('选中一段没被占的字 → 出现按钮，并说清选了几个字', (tester) async {
    await pump(tester);
    final state = tester.state<LineTextPickerState>(find.byType(LineTextPicker));
    state.debugSelect(0, '如果你觉得有点贵'.length);
    await tester.pump();

    expect(find.byKey(const Key('pick-add-shot')), findsOneWidget);
    expect(find.textContaining('5 个字'), findsOneWidget,
        reason: '要说清这一镜会拿到哪几个字，别让人猜');
  });

  testWidgets('选区碰到已占用的字 → 按钮不出现', (tester) async {
    await pump(tester, taken: const [(start: 0, end: 5)]);
    final state = tester.state<LineTextPickerState>(find.byType(LineTextPicker));
    state.debugSelect(0, 4);
    await tester.pump();
    expect(find.byKey(const Key('pick-add-shot')), findsNothing);
  });

  testWidgets('部分重叠也不行', (tester) async {
    await pump(tester, taken: const [(start: 0, end: 5)]);
    final state = tester.state<LineTextPickerState>(find.byType(LineTextPicker));
    state.debugSelect(6, 12);
    await tester.pump();
    expect(find.byKey(const Key('pick-add-shot')), findsNothing);
  });

  testWidgets('避开已占用的部分就能划', (tester) async {
    await pump(tester, taken: const [(start: 0, end: 5)]);
    final state = tester.state<LineTextPickerState>(find.byType(LineTextPicker));
    final free = src.indexOf('那就');
    state.debugSelect(free, free + '那就趁现在'.length);
    await tester.pump();
    expect(find.byKey(const Key('pick-add-shot')), findsOneWidget);
  });

  testWidgets('点按钮回调的是**词序号**，不是字符位置', (tester) async {
    int? gotStart;
    int? gotEnd;
    await pump(tester, onPick: (s, e) {
      gotStart = s;
      gotEnd = e;
    });
    final state = tester.state<LineTextPickerState>(find.byType(LineTextPicker));
    state.debugSelect(0, '如果你觉得有点贵'.length);
    await tester.pump();
    await tester.tap(find.byKey(const Key('pick-add-shot')));
    await tester.pump();

    expect(gotStart, 0);
    expect(gotEnd, 5, reason: '「如果/你/觉得/有点/贵」是 5 个单位');
  });

  testWidgets('没有逐字时间时划不了，并说清为什么', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LineTextPicker(
          text: src,
          words: const [],
          takenWordRanges: const [],
          onPick: (_, __) {},
        ),
      ),
    ));
    final state = tester.state<LineTextPickerState>(find.byType(LineTextPicker));
    state.debugSelect(0, 5);
    await tester.pump();
    expect(find.byKey(const Key('pick-add-shot')), findsNothing);
    expect(find.textContaining('还没有配音'), findsOneWidget);
  });
}
