import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/task_lock_banner.dart';

/// 任务被别人（多半是 Agent）占着时，界面必须**说清楚并给出路**。
///
/// 只把编辑禁掉而不说原因，用户只会以为软件坏了——这是本项目反复踩过的坑
/// （见 CLAUDE.md「状态必须可见且可操作」）。
void main() {
  testWidgets('说清楚是谁占着、现在能做什么、什么时候会好', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskLockBanner(holder: 'agent:1234', onTakeover: () {}),
      ),
    ));

    expect(find.textContaining('agent:1234'), findsOneWidget, reason: '要点名');
    expect(find.textContaining('只读'), findsOneWidget);
    expect(find.textContaining('自动解锁'), findsOneWidget, reason: '要说什么时候会好');
    expect(find.byKey(const Key('lock-takeover')), findsOneWidget);
  });

  testWidgets('强制接管要先确认——那会让对方后续的写入被拒绝', (tester) async {
    var taken = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body:
            TaskLockBanner(holder: 'agent:1234', onTakeover: () => taken = true),
      ),
    ));

    await tester.tap(find.byKey(const Key('lock-takeover')));
    await tester.pumpAndSettle();
    expect(find.textContaining('强制接管'), findsWidgets);
    expect(taken, isFalse, reason: '还没确认就不该真的接管');

    await tester.tap(find.byKey(const Key('lock-takeover-confirm')));
    await tester.pumpAndSettle();
    expect(taken, isTrue);
  });

  testWidgets('确认框要说清代价，以及什么不受影响', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskLockBanner(holder: 'agent:1234', onTakeover: () {}),
      ),
    ));
    await tester.tap(find.byKey(const Key('lock-takeover')));
    await tester.pumpAndSettle();

    expect(find.textContaining('写入会被拒绝'), findsOneWidget);
    expect(find.textContaining('已经写进去的改动不受影响'), findsOneWidget);
  });

  testWidgets('是另一个 GUI 占着时换一种说法——多半是上次没正常退出', (tester) async {
    // 进程被杀时 dispose 不会执行，锁要等心跳超时才失效。这时候说
    // 「另一个程序正在操作」，用户会莫名其妙——明明只有他一个人
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskLockBanner(holder: 'gui:72683', onTakeover: () {}),
      ),
    ));
    expect(find.textContaining('没有正常退出'), findsOneWidget);
    expect(find.textContaining('最多一分钟后会自动解锁'), findsOneWidget);
  });

  testWidgets('取消就什么都不做', (tester) async {
    var taken = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body:
            TaskLockBanner(holder: 'agent:1234', onTakeover: () => taken = true),
      ),
    ));
    await tester.tap(find.byKey(const Key('lock-takeover')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(taken, isFalse);
  });
}
