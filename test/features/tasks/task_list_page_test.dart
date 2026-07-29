import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/tasks/task_list_page.dart';

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
}
