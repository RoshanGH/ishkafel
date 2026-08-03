import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/analysis_progress.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/features/tasks/analysis_progress_store.dart';
import 'package:ishkafel/features/tasks/task_card.dart';

RenewTask _task(RenewTaskStatus status) => RenewTask(
      id: 't1',
      name: '滴露_植源喷雾',
      sourcePath: '/v/a.mp4',
      status: status,
      createdAt: DateTime.utc(2026, 7, 31),
      updatedAt: DateTime.utc(2026, 7, 31),
    );

Future<void> _pump(WidgetTester tester,
    {required RenewTaskStatus status, AnalysisProgress? progress}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  if (progress != null) {
    container.read(analysisProgressProvider.notifier).report('t1', progress);
  }
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 240,
          height: 320,
          child: TaskCard(task: _task(status), sourceMissing: false),
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  group('分析中的任务卡要说清「进行到哪一步」', () {
    testWidgets('显示当前阶段的中文说明', (tester) async {
      await _pump(tester,
          status: RenewTaskStatus.analyzing,
          progress: const AnalysisProgress(stage: AnalysisStage.transcribing));

      expect(find.textContaining('识别台词'), findsOneWidget,
          reason: '一条 75 秒素材实测跑了十几分钟，全程只写「分析中」，'
              '用户无从判断是在推进还是卡死了');
    });

    testWidgets('打标阶段带上「已完成 / 共」的计数', (tester) async {
      await _pump(tester,
          status: RenewTaskStatus.analyzing,
          progress: const AnalysisProgress(
              stage: AnalysisStage.taggingShots, done: 12, total: 32));

      expect(find.textContaining('12'), findsWidgets);
      expect(find.textContaining('32'), findsWidgets);
    });

    testWidgets('有计数时进度条是确定态', (tester) async {
      await _pump(tester,
          status: RenewTaskStatus.analyzing,
          progress: const AnalysisProgress(
              stage: AnalysisStage.taggingShots, done: 8, total: 32));

      final bar = tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('task-card-progress')));
      expect(bar.value, closeTo(0.25, 0.001));
    });

    testWidgets('没有计数时进度条是不确定态，而不是停在 0%', (tester) async {
      await _pump(tester,
          status: RenewTaskStatus.analyzing,
          progress: const AnalysisProgress(stage: AnalysisStage.transcribing));

      final bar = tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('task-card-progress')));
      expect(bar.value, isNull,
          reason: '一根卡在 0% 的确定态进度条，看起来就是「卡死了」');
    });

    testWidgets('还没收到任何进度时退回「分析中」，不留空白', (tester) async {
      await _pump(tester, status: RenewTaskStatus.analyzing);

      expect(find.text('分析中'), findsOneWidget);
    });
  });

  group('非分析中的任务不显示进度', () {
    testWidgets('待切分确认的卡片上没有进度条', (tester) async {
      await _pump(tester,
          status: RenewTaskStatus.editing,
          progress: const AnalysisProgress(stage: AnalysisStage.transcribing));

      expect(find.byKey(const Key('task-card-progress')), findsNothing,
          reason: '分析已经结束的任务还挂着进度条，会让人以为它又在跑了');
    });
  });

  group('进度仓库', () {
    test('同一份进度不重复通知（省掉无谓重绘）', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var notifications = 0;
      container.listen(analysisProgressProvider, (_, _) => notifications++);

      const p = AnalysisProgress(stage: AnalysisStage.transcribing);
      container.read(analysisProgressProvider.notifier).report('t1', p);
      container.read(analysisProgressProvider.notifier).report('t1', p);

      expect(notifications, 1);
    });

    test('清除后不再残留', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final store = container.read(analysisProgressProvider.notifier);

      store.report('t1', const AnalysisProgress(stage: AnalysisStage.building));
      store.report('t2', const AnalysisProgress(stage: AnalysisStage.building));
      store.clear('t1');

      expect(container.read(analysisProgressProvider).keys, ['t2'],
          reason: '只清掉自己那条，不能连带把别的任务的进度抹掉');
    });

    test('清除不存在的任务不报错也不产生通知', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var notifications = 0;
      container.listen(analysisProgressProvider, (_, _) => notifications++);

      container.read(analysisProgressProvider.notifier).clear('nope');

      expect(notifications, 0);
    });
  });
}
