import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/features/workbench/subtitle_editor_card.dart';

/// 被替换镜头的字幕编辑器。
///
/// 起因：ASR 按声音时间断句，而「哪里断句好看」是编导的判断——真机上
/// 「了」被判给了下一镜，那一镜的字幕就以一个孤零零的「了」开头。
/// 规则算不对，就给人手改。
void main() {
  List<SubtitleLine>? changed;
  var clearedToAuto = false;

  Future<void> pump(
    WidgetTester tester, {
    bool replaced = true,
    required List<SubtitleLine> lines,
    bool edited = false,
  }) async {
    changed = null;
    clearedToAuto = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SubtitleEditorCard(
            replaced: replaced,
            lines: lines,
            edited: edited,
            onChanged: (v) => changed = v,
            onResetToAuto: () => clearedToAuto = true,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  const two = [
    SubtitleLine(startMs: 0, endMs: 800, text: '了李斯特菌'),
    SubtitleLine(startMs: 800, endMs: 1600, text: '沙门氏菌的游乐场'),
  ];

  testWidgets('没换素材的镜头：不出现——那一段字幕烧在原片里，我们管不着',
      (tester) async {
    await pump(tester, replaced: false, lines: two);

    expect(find.textContaining('字幕'), findsNothing);
  });

  testWidgets('列出每一段，文字可以直接改', (tester) async {
    await pump(tester, lines: two);

    expect(find.byType(TextField), findsNWidgets(2));

    await tester.enterText(find.byType(TextField).first, '李斯特菌');
    await tester.pumpAndSettle();

    expect(changed!.first.text, '李斯特菌',
        reason: '把开头那个孤零零的「了」删掉，正是这个功能存在的理由');
    expect(changed!.first.startMs, 0, reason: '只改文字，时间不动');
  });

  testWidgets('可以删掉一整段', (tester) async {
    await pump(tester, lines: two);

    await tester.tap(find.byKey(const ValueKey('subtitle-remove-0')));
    await tester.pumpAndSettle();

    expect(changed!.length, 1);
    expect(changed!.single.text, '沙门氏菌的游乐场');
  });

  testWidgets('可以加一段', (tester) async {
    await pump(tester, lines: two);

    await tester.tap(find.byKey(const ValueKey('subtitle-add')));
    await tester.pumpAndSettle();

    expect(changed!.length, 3);
  });

  testWidgets('一段都没有时也能加第一段', (tester) async {
    await pump(tester, lines: const []);

    await tester.tap(find.byKey(const ValueKey('subtitle-add')));
    await tester.pumpAndSettle();

    expect(changed!.length, 1);
  });

  testWidgets('没手改过：不摆「改回自动」——本来就是自动的，点了没意义',
      (tester) async {
    await pump(tester, lines: two);

    expect(find.byKey(const ValueKey('subtitle-reset')), findsNothing);
  });

  testWidgets('手改过：标出来，并给「改回自动」', (tester) async {
    await pump(tester, lines: two, edited: true);

    expect(find.textContaining('手改过'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('subtitle-reset')));
    await tester.pumpAndSettle();

    expect(clearedToAuto, isTrue);
  });
}
