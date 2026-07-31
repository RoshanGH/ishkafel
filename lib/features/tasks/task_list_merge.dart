import 'package:collection/collection.dart';

import '../../core/models/renew_task.dart';

/// 一次局部更新的记录：代次号 + 任务 id + 更新后的任务（null 表示已删除）。
///
/// 全程不可变：每条记录一经生成不再改动。
class LocalTaskChange {
  /// 单调递增的代次号，用于判断这次更新是否发生在某次 reload 起步之后
  final int generation;
  final String id;

  /// null 表示这条任务被删除了
  final RenewTask? task;

  const LocalTaskChange({
    required this.generation,
    required this.id,
    this.task,
  });
}

/// 把 reload 期间发生的局部更新重新叠加回磁盘快照。
///
/// `findAll` 的结果是「**开始那一刻**的磁盘快照」（真实实现里是后台 isolate
/// 遍历目录读盘，100 条约 131 ms）。而 reload 仍会在 importFile、分析失败
/// 落库、后台分析结束、重试分析四处被调用，其中后台分析结束发生在任意时刻。
/// 于是存在这样的交错：
/// ① 任务 A 后台分析中 → ② 分析结束调 reload，findAll 起步
/// → ③ 这 ~130 ms 内用户在审片台点「确认切分」，任务 B 落库成功、内存态
///   已更新、页面 pop → ④ 步骤②的快照返回，**不含 B'**，覆盖 state。
/// 结果是磁盘上 B 已是 picking + 新 units，内存里还是 awaitingCut + 旧
/// units，且没有任何后续动作会纠正；用户再进 B 会以旧 units 为基线编辑，
/// 再保存就把上一次确认的切分永久覆盖。
///
/// [since] 是 reload 起步时的代次号：只有代次号更大的更新才需要叠加回去。
/// 同一条任务两边都有时按 `updatedAt` 取新——快照里那条可能是后台分析刚
/// 写盘的更新版本，不能被更旧的局部更新盖掉。
List<RenewTask> mergeLocalChanges({
  required List<RenewTask> snapshot,
  required Iterable<LocalTaskChange> changes,
  required int since,
}) {
  final pending =
      changes.where((c) => c.generation > since).toList(growable: false);
  if (pending.isEmpty) return snapshot;

  var merged = snapshot;
  for (final change in pending) {
    final inSnapshot = merged.firstWhereOrNull((t) => t.id == change.id);
    merged = merged.where((t) => t.id != change.id).toList(growable: false);
    final local = change.task;
    // 局部删除：磁盘快照里那条（删除前读到的）也要一并去掉，否则任务会
    // 从列表里「复活」——磁盘上它已经没有了
    if (local == null) continue;
    final newer = inSnapshot != null && inSnapshot.updatedAt.isAfter(local.updatedAt)
        ? inSnapshot
        : local;
    merged = insertByUpdatedAtDesc(merged, newer);
  }
  return merged;
}

/// 按 updatedAt 倒序插入，与 FileTaskRepository.findAll 的排序口径一致。
///
/// 用「找插入位」而不是整表 sort：Dart 的 List.sort 不保证稳定，updatedAt
/// 相同的任务会被随机重排，用户会看到列表无缘无故跳动。
List<RenewTask> insertByUpdatedAtDesc(
    List<RenewTask> sorted, RenewTask task) {
  final at = sorted.indexWhere((t) => t.updatedAt.isBefore(task.updatedAt));
  final index = at < 0 ? sorted.length : at;
  return [...sorted.take(index), task, ...sorted.skip(index)];
}
