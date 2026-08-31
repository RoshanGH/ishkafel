import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/features/director/script_panel.dart';

/// 写台词时**不能每敲一个键就写进文档**。
///
/// 真机上撞到的：手写脚本（没有参考片那条路）时，台词框**打不出中文**。
///
/// 原因是每次按键都触发 `onTextChanged` → 文档更新 → 整个编导台重建。
/// 中文输入法在敲拼音的阶段（composing）同样会触发 onChanged，于是每个
/// 拼音字母都引发一次全树重建，组合状态被打断——字就上不了屏。
///
/// 何况改台词还可能弹「划词的分镜要清掉」的确认框：打字打到一半弹个
/// 对话框出来，更是没法用。
///
/// 旁边那个改字幕的输入框一直是对的做法（失焦才提交），台词框照它改。
void main() {
  Widget panel({
    required ScriptDoc doc,
    required void Function(int, String) onTextChanged,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: ScriptPanel(
            doc: doc,
            selected: 0,
            onSelect: (_) {},
            onInsertAfter: (_) {},
            onRemove: (_) {},
            onMove: (_, _) {},
            onTextChanged: onTextChanged,
          ),
        ),
      );

  testWidgets('一个字一个字地敲，不该一路往文档里写', (tester) async {
    final writes = <String>[];
    final doc = ScriptDoc([ScriptLine.create(text: '')]);
    await tester.pumpWidget(
        panel(doc: doc, onTextChanged: (_, t) => writes.add(t)));

    // 模拟输入法敲拼音的过程：n → ni → nih → niha → nihao
    for (final s in ['n', 'ni', 'nih', 'niha', 'nihao']) {
      await tester.enterText(find.byType(TextField).first, s);
      await tester.pump(const Duration(milliseconds: 30));
    }

    expect(writes, isEmpty,
        reason: '拼音还在敲的时候就往文档里写，会把整个编导台重建一遍，'
            '输入法的组合状态跟着被打断——中文根本打不出来');
  });

  testWidgets('手停下来之后，写进去', (tester) async {
    final writes = <String>[];
    final doc = ScriptDoc([ScriptLine.create(text: '')]);
    await tester.pumpWidget(
        panel(doc: doc, onTextChanged: (_, t) => writes.add(t)));

    await tester.enterText(find.byType(TextField).first, '你好');
    await tester.pump(const Duration(seconds: 2));

    expect(writes, ['你好'], reason: '停手了还不存，人会以为白打了');
  });

  testWidgets('手离开这一行：立刻写进去，别等防抖', (tester) async {
    final writes = <String>[];
    final doc =
        ScriptDoc([ScriptLine.create(text: ''), ScriptLine.create(text: '')]);
    await tester.pumpWidget(
        panel(doc: doc, onTextChanged: (_, t) => writes.add(t)));

    await tester.enterText(find.byType(TextField).first, '看到没有');
    await tester.pump(const Duration(milliseconds: 50));
    expect(writes, isEmpty);

    // 点到第二行去
    await tester.tap(find.byType(TextField).last);
    await tester.pump(const Duration(milliseconds: 100));

    expect(writes, contains('看到没有'),
        reason: '人切走了还压着不写，一旦这一行被拆掉就白打了');
  });
}
