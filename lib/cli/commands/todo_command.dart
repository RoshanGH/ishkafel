import 'dart:io';

import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../cli_output.dart';
import '../external_steps.dart';
import '../todo_view.dart';
import 'analyze_command.dart';

/// `ishkafel todo <task>` —— 把当前欠着的那件外包待办再吐一遍。
///
/// 为什么要有这个命令：`analyze --external=...` 停下来时把待办打在标准输出上，
/// **那是唯一的一份**。调用方一旦丢了它（切了上下文、管道断了），就只剩重跑
/// analyze 一条路——而那会重跑一遍 ASR，既花钱又慢。待办本来就在盘上，
/// 让它能取回来是应该的。
Future<int> runTodoCommand({
  required List<String> rest,
  required Directory dataDir,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel todo <任务 id>');
    return exitBadUsage;
  }
  final id = rest.first;

  final task = await resolveTaskRef(FileTaskRepository(dataDir), id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }

  final state = readAnalysisState(dataDir, id);
  if (state == null || state.pending.isEmpty) {
    // 没有欠着的事不是错误，是一种状态——说清楚就行
    emitJson({'status': 'none', 'why': '这个任务没有欠着的外包步骤'}, out: out);
    return 0;
  }

  if (state.pending.contains(ExternalStep.segment)) {
    emitJson(segmentTodo(id, state.prepared.sentences), out: out);
    return 0;
  }

  emitJson(
    tagTodo(
      id,
      task,
      unitVocabulary: await vocabularyFor(task.unitTagGroups),
      shotVocabulary: await vocabularyFor(task.shotTagGroups),
    ),
    out: out,
  );
  return 0;
}
