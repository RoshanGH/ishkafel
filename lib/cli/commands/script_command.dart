import 'dart:io';

import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../cli_output.dart';
import '../script_view.dart';

/// `ishkafel script <子命令> <任务>` —— 脚本成片这条线的只读入口。
///
/// 与成片翻新是同一个任务对象的两个字段（`units` / `script`），所以共用
/// 仓库与输出层，只在这里开一层新的命名空间。
///
/// 子命令：
/// - `show <task> [--line <i>]`：任务全貌 / 单行详情
/// - `shots <task> --line <i>`：这一行的候选镜头与判断依据
/// - `subtitles <task> --line <i>`：这一行的断句材料
Future<int> runScriptCommand({
  required List<String> rest,
  required Directory dataDir,
  int? line,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.length < 2) {
    sink.writeln('用法：ishkafel script <show|shots|subtitles> <任务 id> '
        '[--line <行号，从 1 起>]');
    return exitBadUsage;
  }
  final sub = rest[0];
  final id = rest[1];
  final task = await resolveTaskRef(FileTaskRepository(dataDir), id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  final doc = task.script;
  if (doc == null) {
    sink.writeln('「${task.name}」不是脚本成片任务——'
        '成片翻新那条线请用 ishkafel task / candidates');
    return exitBadUsage;
  }

  switch (sub) {
    case 'show':
      try {
        // --line 给的是**人看的行号**（从 1 起），内部一律 0 起
        emitJson(
            line == null
                ? scriptTaskJson(task)
                : scriptLineJson(doc, line - 1),
            out: out);
        return 0;
      } on ArgumentError catch (e) {
        sink.writeln('${e.message}');
        return exitBadUsage;
      }
    default:
      sink.writeln('不认识的子命令：$sub（可用：show）');
      return exitBadUsage;
  }
}
