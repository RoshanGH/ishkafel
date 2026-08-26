import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/features/tasks/task_id_badge.dart';

/// 任务编号徽章：**进到任务里也要一眼看见自己在第几号任务上**。
///
/// 人跟 Agent（和跟人）沟通全靠这个号——「#12 的第 3 句配音不对」。
/// 看不到编号，就得退出去列表页找，或者干脆报个任务名让对方去猜。
void main() {
  RenewTask taskWith({int? seq, String id = 'abc123def456'}) => RenewTask(
        id: id,
        name: '滴露',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 26),
        updatedAt: DateTime.utc(2026, 8, 26),
        units: const [],
        seq: seq,
      );

  Future<void> pump(WidgetTester tester, RenewTask task) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: TaskIdBadge(task: task))),
        ),
      );

  testWidgets('显示短编号 #N', (tester) async {
    await pump(tester, taskWith(seq: 12));
    expect(find.text('#12'), findsOneWidget);
  });

  testWidgets('点一下就复制——粘给 Agent 是它唯一的用途', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );

    await pump(tester, taskWith(seq: 12));
    await tester.tap(find.byKey(const Key('task-id-badge')));
    await tester.pumpAndSettle();

    expect(copied, ['#12']);
    // 复制了要说一声，不然人不知道点没点上
    expect(find.textContaining('已复制'), findsOneWidget);
  });

  testWidgets('还没补号的任务显示 id，不显示一个空壳', (tester) async {
    await pump(tester, taskWith(id: 'abc123def456'));
    // 短号是列表页加载时补的；从 CLI 直接唤醒进来可能还没补过
    expect(find.textContaining('abc123'), findsOneWidget);
  });

  testWidgets('没有短号时复制完整 id——那才是对方能用的东西', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await pump(tester, taskWith(id: 'abc123def456'));
    await tester.tap(find.byKey(const Key('task-id-badge')));
    await tester.pumpAndSettle();
    expect(copied, ['abc123def456']);
  });
}
