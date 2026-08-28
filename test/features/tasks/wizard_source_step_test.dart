import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_source_step.dart';

void _noop() {}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {

  /// 用户看着这个界面说的：「现在有三个可用模块，但其实两个就够了。」
  ///
  /// 本地文件和「不用原片从素材拼」并不是两个模块——它们是**同一条线的两种
  /// 起点**（有没有参考片），进去之后干的是同一件事：以片找片、换画面。
  /// 四张卡并列摆着，等于告诉人这里有四种玩法。
  group('第 1 步只选两条线，起点是线里面的事', () {
    testWidgets('顶层只有替换裂变和脚本成片两张卡', (tester) async {
      await tester.pumpWidget(_host(const WizardSourceStep(
        filePath: null,
        onPickFile: _noop,
        onPickBlank: _noop,
        onPickScript: _noop,
      )));

      expect(find.byKey(const Key('wizard-line-replace')), findsOneWidget);
      expect(find.byKey(const Key('wizard-line-script')), findsOneWidget);
      // 起点没选线之前不该露出来
      expect(find.byKey(const Key('wizard-pick-local-file')), findsNothing);
      expect(find.byKey(const Key('wizard-blank-source')), findsNothing);
    });

    testWidgets('点了替换裂变，才露出「有原片 / 不用原片」两种起点',
        (tester) async {
      await tester.pumpWidget(_host(const WizardSourceStep(
        filePath: null,
        line: WizardLine.replace,
        onPickFile: _noop,
        onPickBlank: _noop,
        onPickScript: _noop,
      )));

      expect(find.byKey(const Key('wizard-pick-local-file')), findsOneWidget);
      expect(find.byKey(const Key('wizard-blank-source')), findsOneWidget);
      expect(find.byKey(const Key('wizard-miaoa-source')), findsOneWidget,
          reason: 'miaoa 成片库是替换裂变的另一种「有参考」来源，本期未开放但要在');
    });

    testWidgets('脚本成片的起点在编导台里选，这一步不问', (tester) async {
      await tester.pumpWidget(_host(const WizardSourceStep(
        filePath: null,
        line: WizardLine.script,
        onPickFile: _noop,
        onPickBlank: _noop,
        onPickScript: _noop,
      )));

      expect(find.byKey(const Key('wizard-pick-local-file')), findsNothing);
      expect(find.textContaining('进编导台'), findsOneWidget,
          reason: '要告诉人下一步在哪儿传参考片，不能选完就没下文');
    });
  });
}
