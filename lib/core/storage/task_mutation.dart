import 'dart:io';

import '../log/app_log.dart';
import '../models/renew_task.dart';
import '../models/semantic_unit.dart';
import '../models/unit_uid.dart';
import 'edit_stamp.dart';
import 'task_log.dart';
import 'task_repository.dart';

/// 一次改动的产物：改完的任务 + 这一笔的判断依据 + 该盖戳的位置。
///
/// `before` / `after` 由调用方给，因为**只有它知道哪些事实值得记**。
/// 判据见 `task_log.dart`：Agent 要能只凭日志看出人删掉的那两个分镜是哪一类。
///
/// **`edit` 必须是纯变换，不许有副作用。** `TaskMutation.apply` 在落盘前
/// 发现这段窗口被抢写时会把它**重跑一次**（见 [TaskMutation] 类文档）——
/// 如果 `edit` 里做了不能重复的事（发一次网络请求、追加一次计数），
/// 重跑就会把那件事做两遍。
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
  ///
  /// **下标相对 [task]（这份 `TaskEdit` 自己返回的那一份），不是相对
  /// `edit` 参数里拿到的 `fresh`。** 如果这次改动在 `fresh` 的基础上插入或
  /// 删掉了镜头（`SegmentationEditOps.splitShotAt` / `mergeShotWithPrevious`
  /// 走的正是这条路），按 `fresh` 算出来的下标在 [task] 里已经不指向同一
  /// 个位置了——这和上一轮消灭的「持久化 key 里带下标」是同一个坑，只是
  /// 挪到了这份契约上，同样不会报错，只会盖错镜头。
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
/// 1. **写盘前重读、窗口内被抢写就重跑一轮。** 任务是整份对象落库，没有
///    字段级合并。老实现只在 `apply` 开头重读一次，`edit` 跑完到 `save`
///    之间仍是一段没有版本校验的空窗——两个写入方真撞进这段窗口，后写的
///    照样整份盖掉先写的，而写的人自己不知道，日志里也不会有这一条。
///    现在 `save` 前会再核一次 `updatedAt`（每一笔经过 `apply` 的写入都会
///    把它推到当时的 `DateTime.now()`，天然是版本令牌）：不一致就重读、
///    重跑 `edit`，最多重来一轮；重来一轮之后还不一致，就点名说清、
///    照常落盘（不失败）。**这把窗口从「一次整个改动的思考时间」压缩到
///    「一次同步回调」，不是把它变成零**——`edit` 必须是纯变换的契约
///    （见 [TaskEdit]）正是为这次重跑兜底的前提。
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
  /// [edit] 拿到的 `fresh` 是**刚从盘上重读的**那一份，不是调用方手里的旧快照；
  /// 窗口内被抢写时它还可能被**重跑一次**（见类文档），所以必须是纯变换。
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

    final reconciled = await _reconcileWithLatest(
      taskId: taskId,
      op: op,
      base: fresh,
      result: result,
      edit: edit,
    );

    final stamped = _stamp(reconciled, taskId: taskId, op: op)
        .copyWith(updatedAt: DateTime.now());

    await repo.save(stamped);

    // **落盘之后才记**：报的是存进去的东西，不是打算存的东西
    final logged = TaskLogFile(dataDir: dataDir, taskId: taskId).append(
      by: by,
      actor: actor,
      op: op,
      where: where,
      before: reconciled.before,
      after: reconciled.after,
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

  /// 落盘前核一次：`base` 读出来之后，这条任务有没有被别人抢写过。
  ///
  /// **不一致就重读、重跑一次 `edit`**——`edit` 必须是纯变换（见 [TaskEdit]
  /// 文档）才敢这么做。重跑之后再核一次：还不一致就不再重试（写窗口比想象
  /// 的更挤，无限重试只是把「等待」伪装成「解决」），点名说清、照常返回
  /// 重跑后算出来的结果——**不让 `apply` 因为写撞车而失败**。
  Future<TaskEdit> _reconcileWithLatest({
    required String taskId,
    required String op,
    required RenewTask base,
    required TaskEdit result,
    required TaskEdit Function(RenewTask fresh) edit,
  }) async {
    final afterEdit = await repo.findById(taskId);
    if (afterEdit == null || afterEdit.updatedAt == base.updatedAt) {
      return result;
    }

    // 被抢写过一次：重读、重跑 edit
    final retried = edit(afterEdit);

    // 再核一次——比较的基准是这一次真正用来重跑 edit 的那份（afterEdit），
    // 不是 retried.task.updatedAt：edit 会不会顺手动 updatedAt 是调用方的
    // 事，这里不该依赖它没动过
    final afterRetry = await repo.findById(taskId);
    if (afterRetry != null && afterRetry.updatedAt != afterEdit.updatedAt) {
      // 重试一轮还是被抢写：数据仍然真落盘，只是点名说清这一笔是在
      // 重试之后写的——查的人不能被蒙在鼓里以为这段窗口从没被人碰过
      AppLog.error('这一笔改动落盘前又被抢写了一次（$taskId · $op），'
          '已重试一轮仍有人在写，本次按重试后的最新数据落盘。');
    }
    return retried;
  }

  /// 把来源戳盖到这一笔动过的单元与镜头上。
  ///
  /// 戳长在 `SemanticUnit` / `Shot` 对象自己身上（紧挨 `tagsHandpicked`），
  /// 不是旁挂在任务上的一张按路径索引的表——那种表的 key 里带下标，
  /// 第一次拆镜头就会把「人改过」错记到相邻镜头上，不报错。
  ///
  /// **点了名却没找到目标时不能悄悄丢掉**：戳是「这一处是谁定的」在数据里
  /// 的唯一记录，戳没盖上、日志里那一笔却照记不误，查起来会像一切正常，
  /// Agent 后面就可能把人手挑的东西当成自己的覆盖掉。三类会丢戳的情况——
  /// 任务没有 units、点名的 uid 找不到对应单元、shotIndex 越界——统一在这里
  /// 对一遍「点了名的」和「真盖上的」，没对上的一次性报出来。
  RenewTask _stamp(TaskEdit result, {required String taskId, required String op}) {
    if (result.stampUnits.isEmpty && result.stampShots.isEmpty) {
      return result.task;
    }
    final units = result.task.units;
    final matchedUnits = <String>{};
    final matchedShots = <String>{};

    List<SemanticUnit>? newUnits;
    if (units != null) {
      final stamp = EditStamp(by: by, at: DateTime.now());
      newUnits = [
        for (final unit in units)
          _stampUnit(unit, result, stamp, matchedUnits, matchedShots),
      ];
    }

    _reportMissedStamps(result,
        taskId: taskId,
        op: op,
        matchedUnits: matchedUnits,
        matchedShots: matchedShots);

    // units 本来是 null（没分析过）时绝不能悄悄变成 []——那是另一个事实
    return newUnits == null ? result.task : result.task.copyWith(units: newUnits);
  }

  SemanticUnit _stampUnit(
    SemanticUnit unit,
    TaskEdit result,
    EditStamp stamp,
    Set<String> matchedUnits,
    Set<String> matchedShots,
  ) {
    // 还没发身份的单元（老存档、或刚拆分出来还没跑 ensureUnitUids）uid 是
    // 空串：`stampUnits`/`stampShots` 里的空 uid 不该一次命中所有这样的单元
    if (!isUnitUid(unit.uid)) return unit;

    final shotIndexes = <int>{};
    for (final ref in result.stampShots) {
      if (ref.unitUid != unit.uid) continue;
      if (ref.shotIndex < 0 || ref.shotIndex >= unit.shots.length) continue;
      shotIndexes.add(ref.shotIndex);
      matchedShots.add('${unit.uid}#${ref.shotIndex}');
    }
    final touchedUnit = result.stampUnits.contains(unit.uid);
    if (touchedUnit) matchedUnits.add(unit.uid);
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

  void _reportMissedStamps(
    TaskEdit result, {
    required String taskId,
    required String op,
    required Set<String> matchedUnits,
    required Set<String> matchedShots,
  }) {
    final missedUnits = [
      for (final uid in result.stampUnits)
        if (!matchedUnits.contains(uid)) uid,
    ];
    final missedShots = [
      for (final ref in result.stampShots)
        if (!matchedShots.contains('${ref.unitUid}#${ref.shotIndex}'))
          '${ref.unitUid}#${ref.shotIndex}',
    ];
    if (missedUnits.isEmpty && missedShots.isEmpty) return;
    AppLog.error('这一笔要盖的戳没找到目标，戳没盖上（$taskId · $op'
        '${missedUnits.isEmpty ? '' : '，单元 $missedUnits'}'
        '${missedShots.isEmpty ? '' : '，镜头 $missedShots'}）。');
  }
}
