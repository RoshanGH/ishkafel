import 'dart:io';

import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../cli_output.dart';
import '../task_view.dart';

/// `ishkafel task <id>` —— 打印任务全貌。
///
/// 找不到时给 [exitNotFound] 而不是空对象：调用方要能区分「任务不存在」
/// 与「任务存在但还没分析」——这两种情况的下一步完全不同。
Future<int> runTaskCommand({
  required List<String> rest,
  required Directory dataDir,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel task <任务 id>');
    return exitBadUsage;
  }
  final id = rest.first;
  final task = await resolveTaskRef(FileTaskRepository(dataDir), id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  emitJson(taskToJson(task), out: out);
  return 0;
}
