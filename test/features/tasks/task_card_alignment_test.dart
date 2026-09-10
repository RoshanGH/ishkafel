import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_usage.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/features/tasks/task_card.dart';

/// 一排卡片必须对得齐。
///
/// 2026-09-09 设计走查：空白任务「拼片」那张卡没有「等了多久 / 花了多少」，
/// 那一行整个收起来，于是它的信息区比邻居矮一截、封面被 Expanded 撑高，
/// 标题和说明全部错开一行——三张卡里只有它是歪的。
RenewTask _task(
        {required String id, bool withUsage = false, int? firstReadyMs}) =>
    RenewTask(
      id: id,
      name: '任务 $id',
      sourcePath: '/v/$id.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 9, 9),
      updatedAt: DateTime.utc(2026, 9, 9),
      firstReadyMs: firstReadyMs,
      aiUsage: withUsage
          ? AiUsage.empty.plus(
              model: 'doubao-seed-2-0-mini-260428',
              promptTokens: 120000,
              completionTokens: 8000)
          : AiUsage.empty,
    );

void main() {
  testWidgets('有数的卡和没数的卡，标题在同一条水平线上', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          SizedBox(
              width: 260,
              height: 360,
              child: TaskCard(
                  key: const Key('with'),
                  task: _task(id: 'a', withUsage: true, firstReadyMs: 23000))),
          SizedBox(
              width: 260,
              height: 360,
              child: TaskCard(key: const Key('without'), task: _task(id: 'b'))),
        ]),
      ),
    ));
    await tester.pump();

    final withMetrics = tester.getRect(find.text('任务 a'));
    final without = tester.getRect(find.text('任务 b'));

    expect(without.top, closeTo(withMetrics.top, 0.5),
        reason: '一张卡少了「等了多久/花了多少」，整块信息区就往下掉，'
            '一排卡片看起来是歪的');
  });
}
