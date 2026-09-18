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

  /// 这条播报挂在**全局浮层**上：任何一条任务只要有在场状态就显示，
  /// 静默模式也显示，人正开着**完全可编辑**的工作台时也显示。
  ///
  /// 所以它这句话必须在**哪一页都成立**。原来写的是「这期间界面是只读的」
  /// ——软件里已经没有任何一把锁，那是对用户撒谎；而在场状态现在还有心跳，
  /// 那句假话会显示得比以前更久。
  testWidgets('说清人这会儿能干什么，而且这句话在哪一页都成立', (tester) async {
    await pump(tester,
        b: AgentBroadcast.empty.push('正在导出'), holder: 'Agent');
    expect(find.textContaining('只读'), findsNothing,
        reason: '工作台一道闸都没有，说「只读」是假话');
    expect(find.textContaining('先别跟它抢'), findsOneWidget,
        reason: '不说的话人会以为软件卡了——但要说实话');
    expect(find.textContaining('你照样能自己改'), findsNothing,
        reason: '这条浮层是全局的，它不知道人开着哪一页。'
            '「你能改」在编导台上不成立——**不许作任何能力承诺**，'
            '只给一条到处都对的忠告');
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
