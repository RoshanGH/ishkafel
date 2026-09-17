import 'dart:io';

import '../../core/storage/task_media.dart';
import '../../core/storage/task_artifacts.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_copy.dart';
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

/// `ishkafel task-delete <id> --yes` —— 删掉一条任务，连同它的物料。
///
/// 验收 Agent 卡在这儿：让它「验完自己删掉」，CLI 却没有这条命令。
/// 它的原话——「不是我懒，是 CLI 真的没有这条路」，只能看着界面上的
/// ⋯ 菜单不敢点。**界面上人能删，Agent 就得能删**。
///
/// 要 `--yes` 才真删：这是不可逆的，而 Agent 手快。
Future<int> runTaskDeleteCommand({
  required List<String> rest,
  required Directory dataDir,
  bool yes = false,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel task-delete <任务 id> --yes');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  if (!yes) {
    // 删任务连素材、配音、导出记录一起没，而且回不来。手快的话
    // 一条命令就把人半天的活删了——所以要明确点头
    sink.writeln('这会删掉「${task.name}」'
        '${task.seq != null ? '（#${task.seq}）' : ''}，'
        '连同它的素材、配音、预览产物，**删了回不来**。'
        '确定就加 --yes');
    return exitBadUsage;
  }
  try {
    // 物料按项目存，跟着任务一起走——不留孤儿
    TaskMedia(dataDir: dataDir, taskId: task.id).deleteAll();
    // **清单只有一份**（TaskArtifacts）。这里曾经自己遍历 perTaskDirNames，
    // 于是封面、analysis_work 里的平铺产物、stems 全都删不掉——
    // 而界面那条路（FileTaskArtifactCleaner）走的一直是 of()，两边分叉了
    final artifacts = TaskArtifacts(dataDir);
    artifacts.delete(artifacts.of(task.id));
    await repository.delete(task.id);
  } catch (e) {
    sink.writeln('删除失败：$e');
    return exitFailed;
  }
  emitJson({
    'ok': true,
    'deleted': task.id,
    'name': task.name,
    if (task.seq != null) 'seq': task.seq,
  }, out: out);
  return 0;
}


/// `ishkafel task-rename <id> --name "新名字"` —— 给任务改名。
///
/// 界面上人能改（任务卡的 ⋯ 菜单里），Agent 之前不能。验收 Agent 撞上：
/// 它按要求给任务起名，`ui new-task --name` 那时还没接上，事后又没有
/// 改名的路，于是那条任务永远叫「脚本 08-27 21:52」。
Future<int> runTaskRenameCommand({
  required List<String> rest,
  required Directory dataDir,
  String? name,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty || (name ?? '').trim().isEmpty) {
    sink.writeln('用法：ishkafel task-rename <任务 id> --name "新名字"');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final next = name!.trim();
  await repository.save(task.copyWith(name: next, updatedAt: DateTime.now()));
  emitJson({'ok': true, 'id': task.id, 'name': next, 'was': task.name},
      out: out);
  return 0;
}

/// `ishkafel task-copy <id> [--name "新名字"]` —— 复制一条任务。
///
/// **界面上人能复制，Agent 就得能复制。** 典型用法：同一条原片想试两套
/// 完全不同的替换思路，复制出来各走各的——两条任务此后完全隔离，
/// 改一条不动另一条，删一条也不影响另一条（见 [TaskCopier]）。
Future<int> runTaskCopyCommand({
  required List<String> rest,
  required Directory dataDir,
  String? name,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel task-copy <任务 id> [--name "新名字"]');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  // 还在分析的不给复制：那时产物只有一半，抄出来的副本不能用
  if (taskCopyBlockedReason(task) case final blocked?) {
    sink.writeln(blocked);
    return exitBadUsage;
  }
  final all = await repository.findAll();
  try {
    final copy = await TaskCopier(dataDir).duplicate(
      task,
      newId: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      seq: await nextTaskSeq(repository),
      now: DateTime.now(),
      name: (name ?? '').trim().isEmpty
          ? copiedTaskName(task.name, [for (final t in all) t.name])
          : name!.trim(),
    );
    await repository.save(copy);
    emitJson({
      'ok': true,
      'id': copy.id,
      'name': copy.name,
      if (copy.seq != null) 'seq': copy.seq,
      'copiedFrom': task.id,
      // 复制带走了多少字节：人和 Agent 都该知道这一下占了多少盘
      'bytesCopied': TaskCopier(dataDir).estimatedBytes(task.id),
    }, out: out);
    return 0;
  } catch (e) {
    sink.writeln('复制失败：$e');
    return exitFailed;
  }
}
