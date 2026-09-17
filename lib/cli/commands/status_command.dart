import 'dart:io';

import '../../core/storage/agent_presence.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../cli_output.dart';
import '../task_status.dart';

/// `ishkafel status [<任务>] [--json]` ——
/// **每条任务干到哪了、下一步该敲什么、现场有没有别人在动。**
///
/// 这条命令是给「接手」用的。活儿被打断是常态：人按了停、命令超时、
/// app 关掉了、隔了一天回来接着做。重新接手的 Agent 手里什么上下文都没有，
/// 只能一条条 `show` 去翻，然后**照着流程从头再走一遍**——重新打标
/// （十几分钟、几十次识图）、重新配音（一轮 TTS），全是白花的钱。
///
/// 而且**人在打断期间多半动过手**：自己挑了几个镜头、改了断句、换了音色。
/// 接手的人得先看见这些，别一上来就覆盖掉。
///
/// 所以这里报三样东西：
/// 1. 每一步做完没有、做了多少（照流程排）
/// 2. **下一步照着敲的那条命令**（带真实 id 和行号）
/// 3. 现场情况：此刻谁在动这条任务、它在干什么、最后一次改动是什么时候。
///    **这不是一道闸门**——看清了照样写得进去，只是别蒙着眼睛写
Future<int> runStatusCommand({
  required List<String> rest,
  required Directory dataDir,
  bool json = false,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  final repository = FileTaskRepository(dataDir);
  final all = await repository.findAll();
  if (all.isEmpty) {
    if (json) {
      emitJson({'tasks': const []}, out: out);
    } else {
      sink.writeln('一条任务都还没有。'
          '\n新建：ishkafel ui new-task --mode script --tag-groups <id>（当着人的面）'
          '\n或者：ishkafel script new "名字"（人不在场时更快）');
    }
    return 0;
  }

  final wanted = rest.isEmpty ? null : await resolveTaskRef(repository, rest.first);
  if (rest.isNotEmpty && wanted == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final tasks = wanted != null ? [wanted] : all;

  final rows = <Map<String, dynamic>>[];
  for (final task in tasks) {
    final status = statusOf(task);
    final busy = readAgentPresence(dataDir: dataDir, taskId: task.id);
    rows.add({
      ...status.toJson(),
      // **现场情况**：有人正在动这条任务就说出来。这不是一道闸门——
      // 谁都写得进去，只是别蒙着眼睛写
      if (busy != null) 'busyWith': busy.holder,
      if (busy?.action != null) 'doingNow': busy!.action,
    });
  }

  if (json) {
    emitJson({'tasks': rows}, out: out);
    return 0;
  }

  final w = out ?? stdout;
  for (final row in rows) {
    final seq = row['seq'];
    w.writeln('${seq == null ? '' : '#$seq '}${row['name']}'
        '（${row['kind'] == 'script' ? '脚本成片' : '替换裂变'}）');
    w.writeln('  ${row['stage']}');
    final steps = (row['steps'] as List).cast<Map<String, dynamic>>();
    w.writeln('  ${steps.map((s) => '${s['done'] == true ? '✓' : '·'} '
        '${s['step']} ${s['state']}').join('   ')}');
    if (row['blocking'] != null) {
      for (final b in (row['blocking'] as List)) {
        w.writeln('  ⚠ $b');
      }
    }
    if (row['busyWith'] != null) {
      w.writeln('  现在「${row['busyWith']}」在动它'
          '${row['doingNow'] == null ? '' : '：${row['doingNow']}'}');
    }
    if (row['next'] != null) w.writeln('  下一步：${row['next']}');
    w.writeln('  最后改动：${row['updatedAt']}');
    w.writeln();
  }
  return 0;
}
