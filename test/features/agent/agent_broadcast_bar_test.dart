import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/agent_broadcast.dart';
import 'package:ishkafel/features/agent/agent_broadcast_bar.dart';

/// 播报条：人在旁边看着 Agent 干活时，唯一能读到的东西。
void main() {
  Future<void> pump(WidgetTester tester,
          {required AgentBroadcast b, String? holder}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
              children: [AgentBroadcastBar(broadcast: b, holder: holder)]),
        ),
      ));

  testWidgets('没人在干活时整条不出现——平时不该占着屏幕', (tester) async {
    await pump(tester, b: AgentBroadcast.empty.push('做点什么'));
    expect(find.byKey(const Key('broadcast-title')), findsNothing);
  });

  testWidgets('干活时把每一步都列出来，最新的在最下', (tester) async {
    await pump(tester,
        b: AgentBroadcast.empty
            .push('正在新建任务')
            .push('正在提取台词')
            .push('正在给第 3 行找镜头'),
        holder: 'Agent');
    expect(find.text('正在新建任务'), findsOneWidget);
    expect(find.text('正在给第 3 行找镜头'), findsOneWidget);

    final first = tester.getTopLeft(find.text('正在新建任务'));
    final last = tester.getTopLeft(find.text('正在给第 3 行找镜头'));
    expect(last.dy, greaterThan(first.dy),
        reason: '最新的排在最下，视线自然落在底部');
  });

  testWidgets('说清「这期间界面是只读的」——不然人会以为软件卡了', (tester) async {
    await pump(tester,
        b: AgentBroadcast.empty.push('正在导出'), holder: 'Agent');
    expect(find.textContaining('只读'), findsOneWidget);
  });

  testWidgets('做完的打勾，正在做的不打——一眼看出走到哪儿了', (tester) async {
    await pump(tester,
        b: AgentBroadcast.empty.push('第一步').push('第二步'), holder: 'Agent');
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('不拦点击——播报只是让人看见，不该挡住人接手', (tester) async {
    await pump(tester,
        b: AgentBroadcast.empty.push('正在导出'), holder: 'Agent');
    // 播报条自己那一层必须是不拦点击的
    final bar = find.descendant(
        of: find.byType(AgentBroadcastBar), matching: find.byType(IgnorePointer));
    expect(bar, findsWidgets);
    expect(tester.widget<IgnorePointer>(bar.first).ignoring, isTrue);
  });
}
