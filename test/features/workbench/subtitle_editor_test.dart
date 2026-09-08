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

  /// 2026-09-08 真机，用户原话：「我还是可以粘贴，就改字幕我可以粘贴进去汉字，
  /// 但是我打汉字是打不进去的。」
  ///
  /// 中文输入法要先把拼音摆在**候选区**（composing），选好字才上屏。每敲一个
  /// 字母都会走一次 onChanged，父层跟着重建；编辑框如果每次重建都换一个新的
  /// controller，候选区当场被清掉，拼音永远拼不完——而粘贴是一次性整段塞进来，
  /// 不经过候选区，所以粘贴是好的。这个差别正是这条 bug 的指纹。
  group('中文输入法：拼音还在候选区时，父层重建不能把它冲掉', () {
    /// 和真实属性面板一样：onChanged 之后父层 setState 重建
    Future<void> pumpLive(WidgetTester tester) async {
      var lines = const [SubtitleLine(startMs: 0, endMs: 800, text: '')];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SubtitleEditorCard(
              replaced: true,
              lines: lines,
              edited: true,
              onChanged: (v) => setState(() => lines = v),
              onResetToAuto: () {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('敲到一半的拼音还在，候选区没被清掉', (tester) async {
      await pumpLive(tester);
      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();

      // 输入法：'ni' 还在候选区，一个汉字都还没上屏
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ));
      await tester.pumpAndSettle();

      final state =
          tester.state<EditableTextState>(find.byType(EditableText).first);
      expect(state.textEditingValue.text, 'ni');
      expect(state.textEditingValue.composing, const TextRange(start: 0, end: 2),
          reason: '每次重建都新建 controller 的话候选区在这里就没了，'
              '人打第二个字母时前一个已经被吞掉——表现就是「汉字打不进去，'
              '只能粘贴」');
    });

    testWidgets('接着敲第二个字母，前面的不会被吞掉', (tester) async {
      await pumpLive(tester);
      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();

      for (final v in const ['n', 'ni', 'nih', 'niha', 'nihao']) {
        tester.testTextInput.updateEditingValue(TextEditingValue(
          text: v,
          selection: TextSelection.collapsed(offset: v.length),
          composing: TextRange(start: 0, end: v.length),
        ));
        await tester.pumpAndSettle();
      }

      final state =
          tester.state<EditableTextState>(find.byType(EditableText).first);
      expect(state.textEditingValue.text, 'nihao');
      expect(state.textEditingValue.composing.isValid, isTrue);
    });

    testWidgets('外面把内容换掉（改回自动）时，框里要跟着变', (tester) async {
      // 这是当初每帧新建 controller 想解决的问题，改法不能把它弄丢
      var lines = const [SubtitleLine(startMs: 0, endMs: 800, text: '旧的')];
      late StateSetter setOuter;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(builder: (context, setState) {
            setOuter = setState;
            return SubtitleEditorCard(
              replaced: true,
              lines: lines,
              edited: true,
              onChanged: (v) => setState(() => lines = v),
              onResetToAuto: () {},
            );
          }),
        ),
      ));
      await tester.pumpAndSettle();

      setOuter(() =>
          lines = const [SubtitleLine(startMs: 0, endMs: 800, text: '自动算的')]);
      await tester.pumpAndSettle();

      expect(find.text('自动算的'), findsOneWidget);
      expect(find.text('旧的'), findsNothing);
    });

    testWidgets('删掉一段之后，剩下那段的文字不会串位', (tester) async {
      // controller 按行下标复用，删掉第 0 行时第 1 行会顶上来
      var lines = const [
        SubtitleLine(startMs: 0, endMs: 800, text: '第一段'),
        SubtitleLine(startMs: 800, endMs: 1600, text: '第二段'),
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SubtitleEditorCard(
              replaced: true,
              lines: lines,
              edited: true,
              onChanged: (v) => setState(() => lines = v),
              onResetToAuto: () {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('subtitle-remove-0')));
      await tester.pumpAndSettle();

      expect(find.text('第二段'), findsOneWidget);
      expect(find.text('第一段'), findsNothing,
          reason: 'controller 没跟着挪的话，删完第一行框里还留着「第一段」，'
              '而数据里已经是「第二段」——人再敲一下就把内容改错了');
    });
  });
}
