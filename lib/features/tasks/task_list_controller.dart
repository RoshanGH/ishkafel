import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/renew_task.dart';
import '../../core/storage/task_repository.dart';
import '../import_flow/import_service.dart';

/// 由 main.dart（或测试）override 提供实例
final taskRepositoryProvider = Provider<TaskRepository>(
    (ref) => throw UnimplementedError('在 ProviderScope 中 override'));
final importServiceProvider = Provider<ImportService>(
    (ref) => throw UnimplementedError('在 ProviderScope 中 override'));

class TaskListController extends AsyncNotifier<List<RenewTask>> {
  @override
  Future<List<RenewTask>> build() => ref.read(taskRepositoryProvider).findAll();

  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
        () => ref.read(taskRepositoryProvider).findAll());
  }

  Future<void> importFile(String path) async {
    await ref.read(importServiceProvider).importLocalFile(path);
    await reload();
  }
}

final taskListProvider =
    AsyncNotifierProvider<TaskListController, List<RenewTask>>(
        TaskListController.new);
