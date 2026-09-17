import 'dart:io';

import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// 造一条最小可用的任务并落盘，返回它。
///
/// 字段照 `test/cli/clean_command_test.dart` 里那份最小构造——只给必填的五个，
/// 多给一个字段就多一处将来要跟着模型改的地方。
Future<RenewTask> seedTask(
  Directory dataDir, {
  String id = 't_1',
  String name = '测试任务',
}) async {
  final task = RenewTask(
    id: id,
    name: name,
    status: RenewTaskStatus.ready,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
  await FileTaskRepository(dataDir).save(task);
  return task;
}
