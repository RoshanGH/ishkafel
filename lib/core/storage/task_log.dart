import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';

/// 这一笔是人干的还是 Agent 干的。
///
/// **产品负责人点名要的**：「这个日志是要区分人的操作和 Agent 操作的」。
/// 只有两个值——第三个值（比如「系统」）会让 Agent 多一类要猜的东西，
/// 而后台管线跑的活儿本来就是 Agent 让它跑的，算 Agent 的。
enum ActorKind { human, agent }

/// 日志里的一笔。
///
/// **`before` / `after` 放的是事实，不是 id。** 判据是产品负责人举的例子：
/// Agent 挑了四五个分镜、人删了其中两个，Agent 要能只凭日志看出「人不要的是
/// 产品特写那一类」。只记「删除 U3S1」它什么也看不出来；把素材的标签、时长、
/// 画面描述、烧没烧字一起记下，意图就在那儿了。
class TaskLogEntry {
  /// 单调递增，是 `--since` 的游标
  final int seq;
  final DateTime at;
  final ActorKind by;

  /// 具体是谁：`人（工作台）` / `Agent`。出问题时要说得出名字
  final String actor;
  final String taskId;

  /// 干了什么：`shot.pick` / `shot.remove` / `unit.segment` …
  final String op;

  /// 动的是哪儿。**按 uid 记，不按下标**——下标会因为删单元、挪单元而漂
  final Map<String, dynamic> where;

  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  /// 人话补一句：「人在时间线上右键删除」
  final String note;

  const TaskLogEntry({
    required this.seq,
    required this.at,
    required this.by,
    required this.actor,
    required this.taskId,
    required this.op,
    this.where = const {},
    this.before,
    this.after,
    this.note = '',
  });

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'at': at.toIso8601String(),
        'by': by.name,
        'actor': actor,
        'task': taskId,
        'op': op,
        if (where.isNotEmpty) 'where': where,
        if (before != null) 'before': before,
        if (after != null) 'after': after,
        if (note.isNotEmpty) 'note': note,
      };

  /// 宽松解析：**任何一处不对就返回 null**，由调用方跳过这一行。
  /// 一行读不懂的记录不该把整份日志废掉
  static TaskLogEntry? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final seq = raw['seq'];
    final at = DateTime.tryParse('${raw['at']}');
    final op = raw['op'];
    if (seq is! int || at == null || op is! String || op.isEmpty) return null;
    return TaskLogEntry(
      seq: seq,
      at: at,
      by: ActorKind.values.firstWhere((k) => k.name == raw['by'],
          orElse: () => ActorKind.agent),
      actor: raw['actor'] is String ? raw['actor'] as String : '',
      taskId: raw['task'] is String ? raw['task'] as String : '',
      op: op,
      where: raw['where'] is Map
          ? Map<String, dynamic>.from(raw['where'] as Map)
          : const {},
      before: raw['before'] is Map
          ? Map<String, dynamic>.from(raw['before'] as Map)
          : null,
      after: raw['after'] is Map
          ? Map<String, dynamic>.from(raw['after'] as Map)
          : null,
      note: raw['note'] is String ? raw['note'] as String : '',
    );
  }
}

/// 一条任务一份日志：`<dataDir>/logs/<taskId>.jsonl`，一行一条。
///
/// **用文件而不是内存**：CLI 与 GUI 是两个进程，磁盘是它们唯一的公共地面。
/// 这和任务锁当初选文件是同一个理由——只不过锁要删了，日志留下。
///
/// **跟着任务走**：任务删了日志一起删（[deleteAll]），不留孤儿数据。
class TaskLogFile {
  final Directory dataDir;
  final String taskId;

  TaskLogFile({required this.dataDir, required this.taskId});

  File get _file => File(p.join(dataDir.path, 'logs', '$taskId.jsonl'));

  /// 现在记到第几条。文件不在、读不动都返回 0
  int get latestSeq {
    final entries = read(limit: 1 << 30);
    return entries.isEmpty ? 0 : entries.last.seq;
  }

  /// 记一笔，返回它的 seq。
  ///
  /// **追加写**：并发追加时各自成行，不会互相截断（同一条任务同时有两个写入方
  /// 正是锁删掉之后的常态）。
  int append({
    required ActorKind by,
    required String actor,
    required String op,
    Map<String, dynamic> where = const {},
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    String note = '',
  }) {
    final seq = latestSeq + 1;
    final entry = TaskLogEntry(
      seq: seq,
      at: DateTime.now(),
      by: by,
      actor: actor,
      taskId: taskId,
      op: op,
      where: where,
      before: before,
      after: after,
      note: note,
    );
    try {
      final f = _file;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('${jsonEncode(entry.toJson())}\n',
          mode: FileMode.append, flush: true);
    } catch (e) {
      // **出声，不吞。** 日志记漏一笔，Agent 查到的「什么都没发生」
      // 看起来正好像「一切正常」
      AppLog.warn('改动日志写不进去（$taskId · $op）：$e');
    }
    return seq;
  }

  /// 读。`since` 之后的、`by` 那一方的，最多 `limit` 条（取最近的）
  List<TaskLogEntry> read({int? since, ActorKind? by, int limit = 200}) {
    final f = _file;
    if (!f.existsSync()) return const [];
    final out = <TaskLogEntry>[];
    try {
      for (final line in f.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        TaskLogEntry? entry;
        try {
          entry = TaskLogEntry.tryFromJson(jsonDecode(line));
        } catch (_) {
          entry = null;
        }
        // 读不懂的那一行跳过就是了，别让它废掉整份日志
        if (entry == null) continue;
        if (since != null && entry.seq <= since) continue;
        if (by != null && entry.by != by) continue;
        out.add(entry);
      }
    } catch (e) {
      AppLog.warn('改动日志读不动（$taskId）：$e');
      return const [];
    }
    return out.length <= limit ? out : out.sublist(out.length - limit);
  }

  /// 任务删了就把日志一起删——不留孤儿数据
  void deleteAll() {
    try {
      final f = _file;
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      AppLog.warn('改动日志删不掉（$taskId）：$e');
    }
  }
}
