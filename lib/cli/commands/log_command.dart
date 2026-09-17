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
  // 参数不对当场拒绝，不许一路捅进 TaskLogFile.read 才炸——那样退出码就
  // 不属于「参数不对/找不到/环境坏了/干了没成」这四类中的任何一类了
  final argError = _validateArgs(since: since, limit: limit, sink: sink);
  if (argError != null) return argError;

  final task = await resolveTaskRef(FileTaskRepository(dataDir), rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }

  // 写错的过滤条件要当场点名。默默返回空列表的话，人和 Agent 都会
  // 以为「真的什么都没发生」——那是这个项目栽过的「三态混成两态」
  ActorKind? filter;
  if (by != null && by.trim().isNotEmpty) {
    filter = _parseByFilter(by);
    if (filter == null) {
      sink.writeln('--by 要是 human 或 agent 之一（你给的是「$by」）');
      return exitBadUsage;
    }
  }

  List<TaskLogEntry> entries;
  try {
    entries = TaskLogFile(dataDir: dataDir, taskId: task.id)
        .read(since: since, by: filter, limit: limit);
  } catch (e) {
    // 「日志读不动」和「没有改动」是两回事：前者是环境出了问题（权限、
    // 文件被误动过……），不能悄悄退化成后者——那样 Agent 会把「查不动」
    // 当成「一切正常」，这正是这份日志要杜绝的事，源头本身不能先犯
    sink.writeln('改动日志读不动：$e');
    return exitFailed;
  }

  if (entries.isEmpty) {
    // 「没有改动」和「过滤条件太窄，什么都没查到」要分得开：点名当前
    // 生效的过滤条件，别让人以为这条任务真的从没被动过
    sink.writeln('这条任务还没有改动记录'
        '${_filterDescription(since: since, by: filter, limit: limit)}。');
    if (json) emitJson({'ok': true, 'entries': 0, 'cursor': since ?? 0}, out: out);
    return 0;
  }

  if (json) {
    for (final e in entries) {
      emitJson(e.toJson(), out: out);
    }
    return 0;
  }

  _renderHuman(entries, out ?? stdout);
  return 0;
}

/// `--since` 要不小于 0，`--limit` 要是正整数——不对就返回退出码，
/// 调用方直接照它退出；合法返回 null
int? _validateArgs({
  required int? since,
  required int limit,
  required StringSink sink,
}) {
  if (since != null && since < 0) {
    sink.writeln('--since 要是不小于 0 的整数（你给的是 $since）');
    return exitBadUsage;
  }
  if (limit <= 0) {
    sink.writeln('--limit 要是大于 0 的整数（你给的是 $limit）');
    return exitBadUsage;
  }
  return null;
}

/// 把 `--by` 的原始字符串解析成 [ActorKind]，认不出来（大小写不论）就是
/// null——调用方据此当场点名，不猜一个归属出来
ActorKind? _parseByFilter(String raw) => ActorKind.values
    .where((k) => k.name == raw.trim().toLowerCase())
    .firstOrNull;

/// 「没有改动」提示里要不要点名当前的过滤条件——不点名的话，
/// 「这条任务真的从没被动过」和「过滤条件太窄，什么都没匹配到」看着
/// 一模一样，又是一次「三态混成两态」
String _filterDescription({
  required int? since,
  required ActorKind? by,
  required int limit,
}) {
  final parts = <String>[
    if (since != null) '游标 $since 之后',
    if (by != null) '只看 ${by.name}',
    if (limit != 200) '至多 $limit 条',
  ];
  return parts.isEmpty ? '' : '（${parts.join('，')}）';
}

/// 人看的版式：最新的在最上面
void _renderHuman(List<TaskLogEntry> entries, StringSink w) {
  final now = DateTime.now();
  for (final e in entries.reversed) {
    final who = e.by == ActorKind.human ? '人' : 'Agent';
    w.writeln('#${e.seq}  ${_formatAt(e.at, now)}  $who  ${e.op}'
        '${e.where.isEmpty ? '' : '  ${e.where}'}');
    if (e.note.isNotEmpty) w.writeln('        ${e.note}');
    for (final line in _diffLines(e.before, e.after)) {
      w.writeln('        ├ $line');
    }
  }
}

/// `before`/`after` 按字段对齐显示，不能直接 `{...?before, ...?after}`
/// 展开——同名字段会被 after 悄悄盖掉 before，「它原来是什么」就此消失。
/// 而这条命令的立身之本正是这个对比：Agent 要能从「原来是什么、
/// 现在变成了什么」里看出人的意图，不是只看到「现在是什么」。
/// 两边都有就显示「旧 → 新」，只有一边就照那一边显示
List<String> _diffLines(
    Map<String, dynamic>? before, Map<String, dynamic>? after) {
  final keys = {...?before?.keys, ...?after?.keys};
  final lines = <String>[];
  for (final key in keys) {
    final hasBefore = before?.containsKey(key) ?? false;
    final hasAfter = after?.containsKey(key) ?? false;
    if (hasBefore && hasAfter) {
      lines.add('$key：${before![key]} → ${after![key]}');
    } else if (hasBefore) {
      lines.add('$key：${before![key]}');
    } else {
      lines.add('$key：${after![key]}');
    }
  }
  return lines;
}

/// 当天只报时分；跨天的话把日期也带出来，不然多日累积的日志里分不清
/// 「今天 21:49」和「上周三 21:49」是哪一笔——而「隔了一天回来接着干」
/// 正是这条命令要覆盖的核心场景
String _formatAt(DateTime at, DateTime now) {
  final hhmm = '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
  final sameDay =
      at.year == now.year && at.month == now.month && at.day == now.day;
  if (sameDay) return hhmm;
  return '${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')} $hhmm';
}
