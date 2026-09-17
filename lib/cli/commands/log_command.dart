import 'dart:io';

import 'package:collection/collection.dart';

import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_log.dart';
import '../../core/storage/task_seq.dart';
import '../cli_output.dart';

/// `ishkafel log <任务>` —— **我不在的时候，这条任务上发生了什么。**
///
/// Agent 每次断开重连读它一遍，就能接上原来的活儿，甚至看出人没说出口的意思：
/// 它挑了四五个分镜、人删了其中两个，光看「删了两个」什么也读不出来，
/// 而把被删那两条的标签、时长、画面描述摆出来，「人不要产品特写那一类」
/// 就自己浮上来了。
///
/// **只记写操作。** 只读的一律不记——人翻了二十个任务又翻回来，那是「现状」
/// 不是「历史」，这份日志不管这个。
Future<int> runLogCommand({
  required List<String> rest,
  required Directory dataDir,

  /// 我上次看到这个游标，给我后面的
  int? since,

  /// 只看 `human` 或 `agent` 干的
  String? by,
  bool json = true,
  int limit = 200,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('要指定任务：\n'
        '  ishkafel log <任务>                 # 人看的版式\n'
        '  ishkafel log <任务> --json          # 一行一条 JSON\n'
        '  ishkafel log <任务> --since <游标>   # 我上次看到这儿，后面呢\n'
        '  ishkafel log <任务> --by human      # 只看人干了什么');
    return exitBadUsage;
  }
  final task = await resolveTaskRef(FileTaskRepository(dataDir), rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }

  // 写错的过滤条件要当场点名。默默返回空列表的话，人和 Agent 都会
  // 以为「真的什么都没发生」——那是这个项目栽过的「三态混成两态」
  ActorKind? filter;
  if (by != null && by.trim().isNotEmpty) {
    filter = ActorKind.values
        .where((k) => k.name == by.trim().toLowerCase())
        .firstOrNull;
    if (filter == null) {
      sink.writeln('--by 要是 human 或 agent 之一（你给的是「$by」）');
      return exitBadUsage;
    }
  }

  final entries = TaskLogFile(dataDir: dataDir, taskId: task.id)
      .read(since: since, by: filter, limit: limit);

  if (entries.isEmpty) {
    // 「没有改动」和「没查成」要分得开：这里是前者，明说
    sink.writeln('这条任务还没有改动记录'
        '${since == null ? '' : '（游标 $since 之后）'}。');
    if (json) emitJson({'ok': true, 'entries': 0, 'cursor': since ?? 0}, out: out);
    return 0;
  }

  if (json) {
    for (final e in entries) {
      emitJson(e.toJson(), out: out);
    }
    return 0;
  }

  final w = out ?? stdout;
  for (final e in entries.reversed) {
    final who = e.by == ActorKind.human ? '人' : 'Agent';
    w.writeln('#${e.seq}  ${_hhmm(e.at)}  $who  ${e.op}'
        '${e.where.isEmpty ? '' : '  ${e.where}'}');
    if (e.note.isNotEmpty) w.writeln('        ${e.note}');
    for (final entry in {...?e.before, ...?e.after}.entries) {
      w.writeln('        ├ ${entry.key}：${entry.value}');
    }
  }
  return 0;
}

String _hhmm(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';
