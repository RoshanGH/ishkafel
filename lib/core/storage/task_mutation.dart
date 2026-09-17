import 'dart:io';

import '../log/app_log.dart';
import '../models/renew_task.dart';
import '../models/semantic_unit.dart';
import 'edit_stamp.dart';
import 'task_log.dart';
import 'task_repository.dart';

/// 一次改动的产物：改完的任务 + 这一笔的判断依据 + 该盖戳的位置。
///
/// `before` / `after` 由调用方给，因为**只有它知道哪些事实值得记**。
/// 判据见 `task_log.dart`：Agent 要能只凭日志看出人删掉的那两个分镜是哪一类。
class TaskEdit {
  final RenewTask task;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  /// 这一笔动了哪几个单元（给 uid）
  final List<String> stampUnits;

  /// 这一笔动了哪几镜。
  ///
  /// **这里的 shotIndex 是用完即弃的**：`apply` 拿它在同一次同步操作里找到
  /// 那个 `Shot` 对象、把戳盖上去，**下标本身不落盘**。戳长在 `Shot` 上，
  /// 拆镜头合镜头时跟着对象走——这正是 2026-09-17 那次返工的结论：
  /// 临时用来定位的下标没问题，被持久化成 key 的下标才有问题。
  final List<ShotRef> stampShots;

  const TaskEdit({
    required this.task,
    this.before,
    this.after,
    this.stampUnits = const [],
    this.stampShots = const [],
  });
}

/// **唯一的任务写入口。** 界面和 CLI 都走它，谁都不许自己 `repo.save`。
///
/// 两条理由，缺一不可：
///
/// 1. **写盘前重读。** 任务是整份对象落库，没有字段级合并。拿五分钟前的快照
///    整份写回，会把这中间别人改的东西抹掉——**而写的人自己不知道它抹了，
///    所以日志里也不会有这一条**。日志就成了假账，而假账比没账更糟。
///    锁删掉之后同一条任务真的会有两个写入方，这一条是底线。
/// 2. **一处记账。** 日志漏记一笔，Agent 查到的「什么都没发生」看起来正好像
///    「一切正常」。所以不给各命令自己去 `append` 的机会。
///
/// 这个项目在「同一件事两处算」上栽过不止三次，日志是第四次的完美候选。
class TaskMutation {
  final TaskRepository repo;
  final Directory dataDir;

  /// 这个写入方是人还是 Agent
  final ActorKind by;

  /// 具体是谁：`人（工作台）` / `Agent`
  final String actor;

  const TaskMutation({
    required this.repo,
    required this.dataDir,
    required this.by,
    required this.actor,
  });

  /// 改一笔。任务不在就返回 null（**那是事实，不是权限**），否则返回改完的任务。
  ///
  /// [edit] 拿到的 `fresh` 是**刚从盘上重读的**那一份，不是调用方手里的旧快照。
  Future<RenewTask?> apply({
    required String taskId,
    required String op,
    Map<String, dynamic> where = const {},
    String note = '',
    required TaskEdit Function(RenewTask fresh) edit,
  }) async {
    final fresh = await repo.findById(taskId);
    if (fresh == null) return null;

    // edit 抛出来就让它抛：没落盘就不该记日志，记了就是假账
    final result = edit(fresh);

    final stamped = _stamp(result);

    await repo.save(stamped);

    // **落盘之后才记**：报的是存进去的东西，不是打算存的东西
    final logged = TaskLogFile(dataDir: dataDir, taskId: taskId).append(
      by: by,
      actor: actor,
      op: op,
      where: where,
      before: result.before,
      after: result.after,
      note: note,
    );
    if (!logged) {
      // **数据落了盘，账没记上**——只有这里知道这两件事同时成立。
      // 命令不该失败（活儿真干成了），但绝不能不吭声：查日志的人会看到
      // 「什么都没发生」，而那看起来正好像「一切正常」。
      // AppLog 默认写 stderr，CLI 没改过出口，所以这句到得了 Agent 手上
      AppLog.error('这一笔改动已经落盘，但没记进日志（$taskId · $op）——'
          '后面查 ishkafel log 会看不到它。');
    }
    return stamped;
  }

  /// 把来源戳盖到这一笔动过的单元与镜头上。
  ///
  /// 戳长在 `SemanticUnit` / `Shot` 对象自己身上（紧挨 `tagsHandpicked`），
  /// 不是旁挂在任务上的一张按路径索引的表——那种表的 key 里带下标，
  /// 第一次拆镜头就会把「人改过」错记到相邻镜头上，不报错。
  RenewTask _stamp(TaskEdit result) {
    if (result.stampUnits.isEmpty && result.stampShots.isEmpty) {
      return result.task;
    }
    final units = result.task.units;
    if (units == null) return result.task;

    final now = DateTime.now();
    final stamp = EditStamp(by: by, at: now);
    final newUnits = [
      for (final unit in units)
        _stampUnit(unit, result, stamp),
    ];
    return result.task.copyWith(units: newUnits);
  }

  SemanticUnit _stampUnit(SemanticUnit unit, TaskEdit result, EditStamp stamp) {
    final shotIndexes = [
      for (final ref in result.stampShots)
        if (ref.unitUid == unit.uid) ref.shotIndex,
    ];
    final touchedUnit = result.stampUnits.contains(unit.uid);
    if (!touchedUnit && shotIndexes.isEmpty) return unit;

    return unit.copyWith(
      editedBy: touchedUnit ? stamp : null,
      shots: shotIndexes.isEmpty
          ? null
          : [
              for (var i = 0; i < unit.shots.length; i++)
                shotIndexes.contains(i)
                    ? unit.shots[i].copyWith(editedBy: stamp)
                    : unit.shots[i],
            ],
    );
  }
}
