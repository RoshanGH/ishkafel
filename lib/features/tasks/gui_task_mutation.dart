import 'dart:io';

import '../../core/storage/task_log.dart';
import '../../core/storage/task_mutation.dart';
import '../../core/storage/task_repository.dart';

/// 界面这一侧的 `actor`：**具体是哪一张台子上的人**。
///
/// 出问题时要说得出名字——「人改的」不够，得知道他是在工作台拖边界，
/// 还是在审片台剔候选。
const actorWorkbench = '人（工作台）';
const actorDirector = '人（编导台）';
const actorReview = '人（审片台）';
const actorTaskList = '人（任务列表）';

/// 界面这一侧的写入口。**`by` 一律 `human`**。
///
/// 判据是**触发者**，不是代码位置：界面上发生的写入都是人点出来的。
/// 连「启动自检把上次中断的分析标成可重试」「把上次没打完的标补上」这类
/// 软件自己的后台活儿也算在人这一侧——它们不是 Agent 让它跑的，是人打开
/// 这个 app 带出来的；具体是软件在动手，由 `note` 说清楚。
///
/// Agent 那一侧走 CLI，自己构造 `by: ActorKind.agent` 的入口；
/// 管线（`AnalysisPipeline`）两边都在用，所以它把 `by`/`actor` 做成参数，
/// 谁触发就传谁，不在管线里写死。
///
/// [dataDir] 是改动日志的落点（`<dataDir>/logs/<taskId>.jsonl`），正常接线
/// 由 `main.dart` override 给出。**为 null 时直接抛**：日志漏记一笔，
/// Agent 查到的「什么都没发生」看起来正好像「一切正常」——悄悄少记比
/// 当场炸一下危险得多。测试里 override `dataDirProvider` 就行。
TaskMutation humanMutation({
  required TaskRepository repo,
  required Directory? dataDir,
  required String actor,
}) {
  if (dataDir == null) {
    throw StateError('数据目录没接线（dataDirProvider 为 null），这次改动没法记进'
        '改动日志，因此不写。测试里请 override dataDirProvider。');
  }
  return TaskMutation(
      repo: repo, dataDir: dataDir, by: ActorKind.human, actor: actor);
}
