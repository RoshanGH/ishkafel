import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/features/tasks/task_card_menu.dart';

RenewTask _task() => RenewTask(
      id: 'c1',
      name: '滴露_植源喷雾',
      sourcePath: '/v/c1.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 9, 14),
      updatedAt: DateTime.utc(2026, 9, 14),
    );

/// 把确认框弹出来，返回按钮回传的值（点之前是 null）
Future<bool?> _open(WidgetTester tester,
    {required int bytes, String newName = '滴露_植源喷雾 的副本'}) async {
  bool? answer;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer = await confirmCopyTask(context, _task(),
                bytes: bytes, newName: newName);
          },
          child: const Text('复制'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('复制'));
  await tester.pumpAndSettle();
  return answer;
}

void main() {
  group('复制任务的确认框', () {
    testWidgets('先把新名字摆出来——人点之前就知道会多出哪一条', (tester) async {
      await _open(tester, bytes: 67 * 1048576);

      expect(find.textContaining('滴露_植源喷雾 的副本'), findsOneWidget);
    });

    testWidgets('说清要占多少盘：几十上百兆的事不能点完才发现', (tester) async {
      await _open(tester, bytes: 67 * 1048576);

      expect(find.textContaining('67 MB'), findsOneWidget);
    });

    testWidgets('不到 1 MB 的也要给个数，不能显示成 0', (tester) async {
      await _open(tester, bytes: 300 * 1024);

      expect(find.textContaining('0.3 MB'), findsOneWidget);
    });

    testWidgets('把「两条任务此后互不相干」讲明白——这是这个功能的全部前提', (tester) async {
      await _open(tester, bytes: 1048576);

      expect(find.textContaining('完全隔离'), findsOneWidget);
    });

    testWidgets('确认返回 true', (tester) async {
      await _open(tester, bytes: 1048576);
      await tester.tap(find.byKey(const Key('confirm-copy-task')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('取消就是不复制：返回 false，不是 null', (tester) async {
      await _open(tester, bytes: 1048576);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
