import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/side_panel_tabs.dart';

late List<SidePanelTab> changes;

Future<void> _pump(
  WidgetTester tester, {
  SidePanelTab current = SidePanelTab.inspector,
  Map<SidePanelTab, String?> badges = const {},
}) async {
  changes = [];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SidePanelTabBar(
        current: current,
        badges: badges,
        onChanged: changes.add,
      ),
    ),
  ));
}

void main() {
  group('右栏是两个视图，不是两个阶段', () {
    test('只有属性与替换素材两个视图', () {
      expect(SidePanelTab.values.map((t) => t.label), ['属性', '替换素材'],
          reason: '切分和选材本来就是交替进行的——挑着素材发现这刀切得不对，'
              '该直接在时间线上拖一下，而不是退出去改完再进来');
    });

    testWidgets('两个 tab 都在，点哪个回调哪个', (tester) async {
      await _pump(tester);

      await tester.tap(find.text('替换素材'));
      await tester.pump();

      expect(changes, [SidePanelTab.candidates]);
    });

    testWidgets('点当前 tab 也照常回调，由调用方决定要不要忽略', (tester) async {
      await _pump(tester, current: SidePanelTab.inspector);

      await tester.tap(find.text('属性'));
      await tester.pump();

      expect(changes, [SidePanelTab.inspector]);
    });
  });

  group('角标', () {
    testWidgets('有角标时显示在 tab 名后面', (tester) async {
      await _pump(tester, badges: {SidePanelTab.candidates: '3'});

      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('没有角标时不占位', (tester) async {
      await _pump(tester);

      expect(find.text('3'), findsNothing);
      expect(find.text('0'), findsNothing,
          reason: '没选素材时显示一个 0，会被当成「有 0 条可用」的坏消息');
    });
  });
}
