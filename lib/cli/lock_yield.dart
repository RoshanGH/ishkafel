import 'dart:io';

import '../core/storage/agent_request.dart';
import '../core/storage/agent_presence.dart';
import '../core/storage/task_lock.dart';
import '../core/storage/ui_action.dart';

/// 拿这个任务的写锁。**锁不该把活儿挡在门外**——它只该防止两个人同时写坏
/// 同一份数据，而不是让调用方原地放弃。
///
/// 三种占着的情形，三种走法：
///
/// 1. **界面占着**（人打开了这个任务）→ 请它让出来，人留在那一页看着。
///    此前的出路是让界面**退出**那个任务，一退出人就什么都看不见了
/// 2. **另一个 Agent 进程占着，而它还活着** → **等它**，别报错。
///    真机上撞的就是这个：`script voice` 要跑几分钟 25 句 TTS，调用方的
///    命令超时了，它以为失败就再起一个，第二个撞上第一个的锁，然后报告
///    「我会等待锁释放后自动续跑」——**它在等它自己**。等完之后多半发现
///    活儿已经干完了（「没有需要配音的行」），一切正常
/// 3. **占锁的进程已经没了** → `TaskLockFile.acquire` 自己会认出来并接管
///    （见 [TaskLock.isStale]）
Future<bool> acquireYieldingFromUi({
  required TaskLockFile lock,
  required String holder,
  required Directory dataDir,
  required String taskId,
  Duration waitForUi = const Duration(seconds: 8),

  /// 等另一个 Agent 进程干完最多等多久。默认按最慢的一步给
  /// （25 句 TTS 或 47 镜打标都在十几分钟量级）
  Duration waitForAgent = const Duration(minutes: 20),

  /// 每隔多久看一眼锁放没放
  Duration pollEvery = const Duration(seconds: 2),

  /// 等的时候说一声，让调用方知道**不是卡死了**
  void Function(String message)? onWait,
}) async {
  if (lock.acquire(holder)) return true;

  final current = lock.read();
  if (isGuiHolder(current?.holder)) {
    final id = writeAgentRequest(
      dataDir: dataDir,
      taskId: taskId,
      kind: UiAction.lockYield.wire,
      payload: const {},
    );
    final result = await waitForAgentRequest(
        dataDir: dataDir, taskId: taskId, id: id, timeout: waitForUi);
    if (result != null && result.ok && lock.acquire(holder)) return true;
    // 界面没应（多半停在别的页面上，没人接单）——那就没人在看这个任务，
    // 落到下面按「另一个进程占着」处理
  }

  // 另一个 Agent 进程占着：等它干完，而不是把活儿丢回去。
  // **等的时候要出声**，否则调用方看到的是一条命令挂在那儿不动
  final deadline = DateTime.now().add(waitForAgent);
  var announced = false;
  while (DateTime.now().isBefore(deadline)) {
    if (lock.acquire(holder)) return true;
    final who = lock.read();
    if (who == null) continue;
    if (!announced) {
      announced = true;
      final busy = readAgentPresence(dataDir: dataDir, taskId: taskId)?.action;
      onWait?.call('这个任务正被「${who.holder}」占着'
          '${busy == null ? '' : '（$busy）'}——**在等它干完，不是卡住了**。'
          '\n如果那是你自己刚起的进程（命令超时了但它还在跑），'
          '别再起一个，等这条返回就行。');
    }
    await Future<void>.delayed(pollEvery);
  }
  return false;
}
