import '../../core/models/renew_task.dart';

/// 任务列表的状态筛选。
///
/// 分组依据是「用户此刻想找什么」，不是状态枚举本身。
///
/// **没有「待处理 / 已完成」这两项**：项目是常驻的，一条原片放在那儿反复出
/// 不同组合，可编辑是常态而不是待办；导出也不是终态——导过一次还能换一批
/// 素材再导。剩下三项各有各的用处：还在跑的、出问题的、想回去找片子的。
enum TaskFilter {
  all('全部'),
  running('分析中'),
  failed('有问题'),
  exported('导出过');

  final String label;

  const TaskFilter(this.label);

  bool matches(RenewTask task) {
    // 分析失败优先归入「有问题」：失败的任务挂在「进行中」里，
    // 用户会一直等一个永远不会完成的东西
    final failed = task.analysisError != null;
    return switch (this) {
      TaskFilter.all => true,
      TaskFilter.failed => failed,
      TaskFilter.running => !failed && task.status == RenewTaskStatus.analyzing,
      // 「导出过」不是终态，只是一个找片子的入口：想回去看昨天导的那批
      TaskFilter.exported => !failed && task.exports.isNotEmpty,
    };
  }
}

/// 按关键词 + 状态过滤，返回**新列表**（不就地改动传入的列表）。
///
/// 关键词同时匹配任务名、任务 id 与短编号（「#12」或「12」都能搜到 #12）。
List<RenewTask> applyTaskFilter(
  List<RenewTask> tasks, {
  String query = '',
  TaskFilter filter = TaskFilter.all,
}) {
  final keyword = query.trim().toLowerCase();
  // 「#12」按编号精确找；纯数字「12」也先试编号（比名字里凑巧含 12 更符合意图）
  final seqQuery = int.tryParse(
      keyword.startsWith('#') ? keyword.substring(1) : keyword);
  return List.unmodifiable(tasks.where((task) =>
      filter.matches(task) &&
      (keyword.isEmpty ||
          (seqQuery != null && task.seq == seqQuery) ||
          task.name.toLowerCase().contains(keyword) ||
          task.id.toLowerCase().contains(keyword))));
}
