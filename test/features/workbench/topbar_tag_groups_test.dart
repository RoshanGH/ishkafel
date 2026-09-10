import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/features/workbench/workbench_chrome.dart';

/// 顶栏那行标签组要说清楚「哪一层用哪几组」。
///
/// 2026-09-09 设计走查真机截图：两层选了同一套五个组，顶栏直接把两个列表
/// 拼成一串，显示成十个名字、后五个跟前五个一模一样。人第一眼以为软件出错。
RenewTask _task({
  List<TagGroupRef> unit = const [],
  List<TagGroupRef> shot = const [],
}) =>
    RenewTask(
      id: 't-1',
      name: '滴露',
      sourcePath: '/v/t-1.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 9, 9),
      updatedAt: DateTime.utc(2026, 9, 9),
      unitTagGroups: unit,
      shotTagGroups: shot,
    );

Future<void> _pump(WidgetTester tester, RenewTask task) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: WorkbenchTopBar(task: task, onBack: () {}),
        ),
      ),
    );

void main() {
  const a = TagGroupRef(id: 1, name: '植源分子库');
  const b = TagGroupRef(id: 2, name: '植源场景');
  const c = TagGroupRef(id: 3, name: '植源动作');

  testWidgets('两层同一套：只列一遍，并说明它管两层', (tester) async {
    await _pump(tester, _task(unit: const [a, b], shot: const [a, b]));

    expect(find.text('标签组 植源分子库 / 植源场景 · 两层同一套'), findsOneWidget);
  });

  testWidgets('两层不一样：分开说，别让人自己去猜哪几组管哪一层', (tester) async {
    await _pump(tester, _task(unit: const [a], shot: const [b, c]));

    expect(find.text('单元 植源分子库 · 镜头 植源场景 / 植源动作'), findsOneWidget);
  });

  testWidgets('只有一层有：说清另一层不打标', (tester) async {
    await _pump(tester, _task(unit: const [a]));

    expect(find.text('单元标签组 植源分子库（镜头层不打标）'), findsOneWidget);
  });

  testWidgets('一组都没有：直说不会打标，而不是什么都不显示', (tester) async {
    await _pump(tester, _task());

    expect(find.text('未设置标签组，不会打标'), findsOneWidget);
  });
}
