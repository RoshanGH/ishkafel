import '../../core/models/renew_task.dart';

/// 任务列表的状态筛选。
///
/// 分组依据是「用户此刻想找什么」，不是状态枚举本身：他要么想找**该我动手
/// 的**，要么想看**还在跑的**，要么在排查**出问题的**。把四个状态原样列成
/// 四个筛选项，反而要他自己在脑子里做这层翻译。
enum TaskFilter {
  all('全部'),
  todo('待处理'),
  running('进行中'),
  failed('有问题'),
  done('已完成');

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
      TaskFilter.todo => !failed &&
          (task.status == RenewTaskStatus.awaitingCut ||
              task.status == RenewTaskStatus.picking),
      TaskFilter.done => !failed && task.status == RenewTaskStatus.exported,
    };
  }
}

/// 按关键词 + 状态过滤，返回**新列表**（不就地改动传入的列表）。
///
/// 关键词同时匹配任务名与任务 id：设计稿的搜索框写的就是「任务名 / ID」。
List<RenewTask> applyTaskFilter(
  List<RenewTask> tasks, {
  String query = '',
  TaskFilter filter = TaskFilter.all,
}) {
  final keyword = query.trim().toLowerCase();
  return List.unmodifiable(tasks.where((task) =>
      filter.matches(task) &&
      (keyword.isEmpty ||
          task.name.toLowerCase().contains(keyword) ||
          task.id.toLowerCase().contains(keyword))));
}
