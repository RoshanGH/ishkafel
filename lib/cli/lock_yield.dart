import 'dart:io';

import '../core/storage/agent_request.dart';
import '../core/storage/task_lock.dart';
import '../core/storage/ui_action.dart';

/// 拿这个任务的写锁。**界面占着的话，请它让出来，人留在那一页看着。**
///
/// 为什么要有这一层：可视模式下人打开的正是这个任务，界面因此占着写锁，
/// 而 Agent 下一步非写它不可。此前的出路是让界面**退出**那个任务——
/// 一退出人就什么都看不见了。于是最慢最贵的那几步（识别台词、逐镜打标、
/// 逐句配音，几分钟、几十次识图 + 几十句 TTS）人对着一块不动的板子干等。
///
/// 验收 Agent 的原话：「最花时间的几步恰好不支持可视……可视模式真正
/// 动起来是从挑镜头才开始。」
///
/// 现在改成：界面把锁让出来、**自己转成只读跟随**——Agent 改哪一行它就
/// 滚到哪一行，数据当场刷出来。人要抢回去，点横幅上的「我来接手」。
///
/// 界面没开、或者占锁的是另一个 Agent 时，这里什么都不做——那两种情况
/// 本来就没有「让位」这回事，照旧返回 false 让调用方报原来那句话。
Future<bool> acquireYieldingFromUi({
  required TaskLockFile lock,
  required String holder,
  required Directory dataDir,
  required String taskId,
  Duration waitForUi = const Duration(seconds: 8),
}) async {
  if (lock.acquire(holder)) return true;
  if (!isGuiHolder(lock.read()?.holder)) return false;

  final id = writeAgentRequest(
    dataDir: dataDir,
    taskId: taskId,
    kind: UiAction.lockYield.wire,
    payload: const {},
  );
  final result = await waitForAgentRequest(
      dataDir: dataDir, taskId: taskId, id: id, timeout: waitForUi);
  if (result == null || !result.ok) return false;
  return lock.acquire(holder);
}
