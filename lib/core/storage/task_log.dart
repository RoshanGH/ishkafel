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
  /// 单调递增，是 `--since` 的游标。
  ///
  /// **不落盘，读的时候现算。** 早先版本把 seq 写进 JSON、`append` 靠
  /// `读 latestSeq → +1 → 写` 得出下一个号，这是一次读-改-写，CLI 和 GUI
  /// 两个进程同时 `append` 会算出同一个 seq——不是数字难看，是撞号的那一笔
  /// 从此在 `--since` 游标下永远查不到，等于凭空消失。改成按 `read()` 里
  /// 成功解析到的行序赋号，`append` 就只是纯追加，不必读文件，竞态随之
  /// 消失。
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
        // seq 不写进去——它是读的时候按行序现算的，见 [seq] 的注释
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
  /// 一行读不懂的记录不该把整份日志废掉。
  ///
  /// **`by` 解析不出合法值也算坏行**，不猜成某一方。这份日志存在的唯一
  /// 意义就是分清人和 Agent，猜一个归属就是把「人 / Agent / 不知道」这
  /// 三态悄悄压成两态——这正是这个项目栽过的毛病。
  ///
  /// 返回的 `seq` 是占位值 0，真正的号由 [TaskLogFile.read] 按解析成功的
  /// 行序重新赋予（seq 不落盘，见 [seq] 的注释）。
  static TaskLogEntry? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at']}');
    final op = raw['op'];
    if (at == null || op is! String || op.isEmpty) return null;
    ActorKind? by;
    for (final k in ActorKind.values) {
      if (k.name == raw['by']) {
        by = k;
        break;
      }
    }
    if (by == null) return null;
    return TaskLogEntry(
      seq: 0,
      at: at,
      by: by,
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

  /// 现在记到第几条。**文件不在**返回 0；文件在但读不动跟着 [read] 抛
  /// （见 [read] 的注释：那不是「没有」，装不得）
  int get latestSeq {
    final entries = read(limit: 1 << 30);
    return entries.isEmpty ? 0 : entries.last.seq;
  }

  /// 记一笔，返回是否真的落盘了。
  ///
  /// **纯追加，不读文件。** 不再算 `latestSeq + 1`——seq 已经不落盘（见
  /// [TaskLogEntry.seq] 的注释），`append` 不需要先读旧内容才能知道该写
  /// 什么，两个写入方（CLI、GUI）谁先谁后都不用互相协调，读-改-写的竞态
  /// 随之消失。
  ///
  /// 返回值补上了「到底写没写进去」——调用方不该拿到一个看起来正常的
  /// 返回值，磁盘上却什么都没发生。
  bool append({
    required ActorKind by,
    required String actor,
    required String op,
    Map<String, dynamic> where = const {},
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    String note = '',
  }) {
    final entry = TaskLogEntry(
      seq: 0, // 占位，不落盘（toJson 里不写这个字段）
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
      return true;
    } catch (e) {
      // **出声，不吞。** 日志记漏一笔，Agent 查到的「什么都没发生」
      // 看起来正好像「一切正常」
      AppLog.warn('改动日志写不进去（$taskId · $op）：$e');
      return false;
    }
  }

  /// 读。`since` 之后的、`by` 那一方的，最多 `limit` 条（取最近的）。
  ///
  /// **「文件不在」和「文件在但读不了」是两回事。** 前者是这条任务真的
  /// 还没有一笔记录，返回空列表；后者（权限不够、路径被误建成目录……）
  /// **往上抛**，不装成「没有改动」——静默吞掉的话，调用方分不清
  /// 「什么都没发生」和「查不动」，这正是这份日志要防的「三态混成两态」，
  /// 不能自己在源头先犯一遍。
  ///
  /// **`limit` 给非正数不炸。** 调用方（CLI 层）会先一步拒绝非法值，
  /// 但这层自己也不能被任何调用方喂垮——非正数直接当「不要」处理，返回空。
  ///
  /// **seq 在这里现算**：按成功解析的行的次序从 1 开始编号，坏行不占号
  /// （不落盘、也不参与计数）。
  List<TaskLogEntry> read({int? since, ActorKind? by, int limit = 200}) {
    final f = _file;
    // existsSync() 对着一个被误建成目录的路径会返回 false，和「真的没有」
    // 长得一模一样——用 typeSync 才分得清「不存在」和「存在但不是文件」
    if (FileSystemEntity.typeSync(f.path) == FileSystemEntityType.notFound) {
      return const [];
    }
    List<String> lines;
    try {
      lines = f.readAsLinesSync();
    } catch (e) {
      AppLog.warn('改动日志读不动（$taskId）：$e');
      rethrow;
    }
    final out = <TaskLogEntry>[];
    var skipped = 0;
    var seq = 0;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      TaskLogEntry? parsed;
      try {
        parsed = TaskLogEntry.tryFromJson(jsonDecode(line));
      } catch (_) {
        parsed = null;
      }
      // 读不懂的那一行跳过就是了，别让它废掉整份日志
      if (parsed == null) {
        skipped++;
        continue;
      }
      seq++;
      final entry = TaskLogEntry(
        seq: seq,
        at: parsed.at,
        by: parsed.by,
        actor: parsed.actor,
        taskId: parsed.taskId,
        op: parsed.op,
        where: parsed.where,
        before: parsed.before,
        after: parsed.after,
        note: parsed.note,
      );
      if (since != null && entry.seq <= since) continue;
      if (by != null && entry.by != by) continue;
      out.add(entry);
    }
    if (skipped > 0) {
      // 坏行现在还会影响编号，比以前更该让人知道有几行没读懂
      AppLog.warn('改动日志有 $skipped 行读不懂，已跳过（$taskId）');
    }
    if (limit <= 0) return const [];
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
