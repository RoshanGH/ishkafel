import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/export_record.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_providers.dart';
import 'package:ishkafel/features/tasks/source_availability.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/tasks/task_list_page.dart';

class _Repo implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async => _store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}

RenewTask _task(String id, String name, RenewTaskStatus status,
        {String? error, List<ExportRecord> exports = const []}) =>
    RenewTask(
      id: id,
      name: name,
      sourcePath: '/v/$id.mp4',
      status: status,
      analysisError: error,
      exports: exports,
      createdAt: DateTime.utc(2026, 7, 31),
      updatedAt: DateTime.utc(2026, 7, 31),
    );

Future<void> _pump(WidgetTester tester) async {
  final repo = _Repo();
  await repo.save(_task('hkv1', '滴露_植源喷雾', RenewTaskStatus.ready));
  await repo.save(_task('hkv2', '卫仕洗衣液', RenewTaskStatus.ready));
  await repo.save(_task('hkv3', '舒肤佳', RenewTaskStatus.ready, exports: [
    ExportRecord(
        at: DateTime.utc(2026, 8, 8),
        total: 6,
        succeeded: 6,
        outputDir: '/out'),
  ]));

  await tester.pumpWidget(ProviderScope(
    overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      fileExistsProbeProvider.overrideWithValue((_) async => true),
      miaoaTagServiceProvider.overrideWithValue(
          MiaoaTagService(run: (_, _) async => ProcessResult(1, 0, '[]', ''))),
      videoFilePickerProvider.overrideWithValue(() async => null),
    ],
    child: const MaterialApp(home: TaskListPage()),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('搜索', () {
    testWidgets('输入关键词后只留下匹配的任务', (tester) async {
      await _pump(tester);
      expect(find.text('舒肤佳'), findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('task-list-search')), '洗衣液');
      await tester.pumpAndSettle();

      expect(find.text('卫仕洗衣液'), findsOneWidget);
      expect(find.text('舒肤佳'), findsNothing);
    });

    testWidgets('搜不到时说清楚，并给一键清除的出口', (tester) async {
      await _pump(tester);

      await tester.enterText(
          find.byKey(const Key('task-list-search')), '不存在');
      await tester.pumpAndSettle();

      expect(find.textContaining('没有匹配'), findsOneWidget,
          reason: '直接给一片空白，用户分不清是「真没有」还是「界面坏了」');

      await tester.tap(find.byKey(const Key('task-list-reset-filter')));
      await tester.pumpAndSettle();
      expect(find.text('舒肤佳'), findsOneWidget);
    });
  });

  group('状态筛选', () {
    testWidgets('点「导出过」只剩导出过的项目——回去找片子的入口', (tester) async {
      await _pump(tester);

      await tester.tap(find.text('导出过 1'));
      await tester.pumpAndSettle();

      expect(find.text('舒肤佳'), findsOneWidget);
      expect(find.text('滴露_植源喷雾'), findsNothing);
    });

    testWidgets('筛选标签上带数量，不点进去也知道有没有东西', (tester) async {
      await _pump(tester);

      expect(find.text('导出过 1'), findsOneWidget);
    });

    testWidgets('某一类一条都没有时给说明，而不是空白', (tester) async {
      await _pump(tester);

      await tester.tap(find.textContaining('有问题'));
      await tester.pumpAndSettle();

      expect(find.textContaining('当前没有'), findsOneWidget);
    });
  });

  group('没有任务时不摆搜索框', () {
    testWidgets('空列表走欢迎页，不显示一个搜不到东西的搜索框', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(_Repo()),
          fileExistsProbeProvider.overrideWithValue((_) async => true),
          miaoaTagServiceProvider.overrideWithValue(MiaoaTagService(
              run: (_, _) async => ProcessResult(1, 0, '[]', ''))),
          videoFilePickerProvider.overrideWithValue(() async => null),
        ],
        child: const MaterialApp(home: TaskListPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('task-list-search')), findsNothing);
      expect(find.byKey(const Key('welcome-start')), findsOneWidget);
    });
  });
}
