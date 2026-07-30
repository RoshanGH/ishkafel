import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/tasks/task_list_page.dart';
import 'package:ishkafel/features/workbench/workbench_page.dart';

/// 内存假实现，避免 UI 测试碰文件系统
class InMemoryTaskRepository implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async {
    final list = _store.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}

RenewTask makeTask(String id, String name, RenewTaskStatus status) => RenewTask(
      id: id, name: name, sourcePath: '/v/$id.mp4', status: status,
      createdAt: DateTime.utc(2026, 7, 29), updatedAt: DateTime.utc(2026, 7, 29),
    );

Widget wrap(TaskRepository repo) => ProviderScope(
      overrides: [taskRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: TaskListPage()),
    );

void main() {
  testWidgets('空状态显示引导文案', (tester) async {
    await tester.pumpWidget(wrap(InMemoryTaskRepository()));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有任务'), findsOneWidget);
  });

  testWidgets('有任务时按卡片渲染名称与状态徽标', (tester) async {
    final repo = InMemoryTaskRepository();
    await repo.save(makeTask('a', '滴露_植源喷雾', RenewTaskStatus.picking));
    await repo.save(makeTask('b', '卫仕洗衣液', RenewTaskStatus.exported));
    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();
    expect(find.text('滴露_植源喷雾'), findsOneWidget);
    expect(find.text('选材中'), findsOneWidget);
    expect(find.text('卫仕洗衣液'), findsOneWidget);
    expect(find.text('已导出'), findsOneWidget);
  });

  group('任务卡点击路由', () {
    RenewTask makeCuttableTask(RenewTaskStatus status) => RenewTask(
          id: 'r1',
          name: '可进入审片台的任务',
          sourcePath: '/v/r1.mp4',
          status: status,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          units: [
            SemanticUnit(
              index: 0,
              startMs: 0,
              endMs: 1000,
              transcript: 't',
              shots: const [Shot(startMs: 0, endMs: 1000)],
            ),
          ],
          videoInfo: const VideoInfo(
            width: 1080,
            height: 1920,
            duration: Duration(milliseconds: 1000),
            fps: 30,
            fileSizeBytes: 10,
          ),
        );

    testWidgets('awaitingCut 且有 units 时点击进入审片台', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeCuttableTask(RenewTaskStatus.awaitingCut));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('可进入审片台的任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsOneWidget);
    });

    testWidgets('picking 状态点击也可进入审片台（允许回看）', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeCuttableTask(RenewTaskStatus.picking));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('可进入审片台的任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsOneWidget);
    });

    testWidgets('analyzing 状态点击不进入审片台，提示分析中', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeTask('a2', '分析中的任务', RenewTaskStatus.analyzing));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('分析中的任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsNothing);
      expect(find.textContaining('分析中'), findsWidgets);
    });
  });

  group('分析失败反馈', () {
    RenewTask makeFailedTask() => makeTask('f1', '失败任务', RenewTaskStatus.analyzing)
        .copyWith(analysisError: '网络连接超时，请检查凭据配置');

    testWidgets('分析失败任务显示红色「分析失败」徽标，优先于状态徽标', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeFailedTask());
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      expect(find.text('分析失败'), findsOneWidget);
      // 状态徽标文案「分析中」不应再出现（被失败徽标顶替）
      expect(find.text('分析中'), findsNothing);
    });

    testWidgets('点击失败任务卡不进入审片台，显示失败原因与「重试」action', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeFailedTask());
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('失败任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsNothing);
      expect(find.textContaining('网络连接超时，请检查凭据配置'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      // 点击「重试」不应崩溃（pipeline 未配置场景，controller 内部会直接返回）
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
    });
  });
}
