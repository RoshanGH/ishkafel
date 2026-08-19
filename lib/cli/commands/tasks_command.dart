import 'dart:io';

import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../cli_output.dart';

/// `ishkafel tasks` —— 列出所有任务（短编号 / id / 名字 / 状态）。
///
/// 人跟 Agent 说的是「#12」这种短编号，Agent 靠这条命令把编号换成 id，
/// 再去调其他命令。顺手补号：CLI 可能先于 GUI 碰到没编号的老任务。
Future<int> runTasksCommand({
  required Directory dataDir,
  StringSink? out,
}) async {
  final repository = FileTaskRepository(dataDir);
  final tasks =
      await ensureTaskSeqs(repository, await repository.findAll());
  final sorted = [...tasks]..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
  emitJson({
    'tasks': [
      for (final t in sorted)
        {
          'seq': t.seq,
          'id': t.id,
          'name': t.name,
          'status': t.status.name,
          'analyzed': t.units != null,
          'analysisError': t.analysisError,
          'createdAt': t.createdAt.toIso8601String(),
        },
    ],
  }, out: out);
  return 0;
}
