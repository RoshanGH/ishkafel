/// 任务短编号（#N）的分配与补号，全仓库只此一处。
///
/// 编号是给**人**用的：任务名冗长且可能重复，跟 Agent 说「把 #12 导出」
/// 才说得清。id 仍是唯一的机器身份，编号只求「当前列表里不重、念得出口」。
library;

import '../log/app_log.dart';
import '../models/renew_task.dart';
import 'task_repository.dart';

/// 下一个可用编号：现存最大号 +1。
///
/// 单机单数据目录，GUI 与 CLI 不会同一毫秒建任务，不引入计数器文件——
/// 那是又一份要迁移、要修坏档的状态。
Future<int> nextTaskSeq(TaskRepository repository) async {
  final tasks = await repository.findAll();
  var max = 0;
  for (final t in tasks) {
    final s = t.seq;
    if (s != null && s > max) max = s;
  }
  return max + 1;
}

/// 旧任务补号：按创建时间从早到晚补（老任务拿小号，跟人对任务的时间直觉
/// 一致），已有号的不动。返回补号后的列表；没有缺号时原样返回。
///
/// 幂等，放在任务列表加载后调用一次即可。
Future<List<RenewTask>> ensureTaskSeqs(
    TaskRepository repository, List<RenewTask> tasks) async {
  if (tasks.every((t) => t.seq != null)) return tasks;
  var next = 0;
  for (final t in tasks) {
    final s = t.seq;
    if (s != null && s > next) next = s;
  }
  final byCreation = [...tasks]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final assigned = <String, int>{};
  for (final t in byCreation) {
    if (t.seq == null) assigned[t.id] = ++next;
  }
  final result = <RenewTask>[];
  for (final t in tasks) {
    final seq = assigned[t.id];
    if (seq == null) {
      result.add(t);
      continue;
    }
    final updated = t.copyWith(seq: seq);
    try {
      await repository.save(updated);
      result.add(updated);
    } catch (e) {
      // 补号失败不能挡加载：下次进来再补。但要留痕，不能静默
      AppLog.warn('任务补编号失败（${t.id} → #$seq）：$e');
      result.add(t);
    }
  }
  return result;
}

/// 把用户/Agent 口中的任务指代解析成任务：先按 id 精确找，再按
/// 「#12」「12」这类编号找。找不到返回 null。
Future<RenewTask?> resolveTaskRef(
    TaskRepository repository, String ref) async {
  final byId = await repository.findById(ref);
  if (byId != null) return byId;
  final seq = int.tryParse(ref.startsWith('#') ? ref.substring(1) : ref);
  if (seq == null) return null;
  final tasks = await repository.findAll();
  for (final t in tasks) {
    if (t.seq == seq) return t;
  }
  return null;
}
