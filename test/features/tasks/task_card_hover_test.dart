import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/features/tasks/task_card.dart';

/// **首页的卡片要让人一眼看出「这能点」。**
///
/// 2026-09-09 设计走查：任务卡是这个 app 的门面、也是最主要的交互对象，
/// 可鼠标移上去毫无反应，光标还是箭头——外面包的 GestureDetector 既不给
/// 光标也不给反馈。
void main() {
  RenewTask task() => RenewTask(
        id: 'h1',
        name: '滴露',
        sourcePath: '/v/h1.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 9),
        updatedAt: DateTime.utc(2026, 9, 9),
      );

  testWidgets('鼠标停上去：光标变手型，卡片描一圈亮边', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 260, height: 360, child: TaskCard(task: task())),
        ),
      ),
    ));
    await tester.pump();

    final region = tester.widget<MouseRegion>(find
        .descendant(
            of: find.byType(TaskCard), matching: find.byType(MouseRegion))
        .first);
    expect(region.cursor, SystemMouseCursors.click,
        reason: '光标不变，人不知道这一张能点');

    // 没停上去时不该有亮边
    AnimatedContainer shell() => tester.widget<AnimatedContainer>(find
        .descendant(
            of: find.byType(TaskCard),
            matching: find.byType(AnimatedContainer))
        .first);
    final before =
        (shell().decoration! as BoxDecoration).border!.top.color;

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(TaskCard)));
    await tester.pumpAndSettle();

    final after = (shell().decoration! as BoxDecoration).border!.top.color;
    expect(after, isNot(before), reason: '停上去要有看得见的变化');
    expect(after.a, greaterThan(0.5), reason: '亮边要真的亮起来');
  });
}
