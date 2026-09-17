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

/// **软件自己干的活儿**的 `actor`。这几笔的 `by` 是 `agent`，理由见
/// [softwareMutation]——`actor` 这一格负责把「具体是谁」说准。
const actorSelfCheck = '软件（启动自检）';
const actorResumeTagging = '软件（补打标）';
const actorAnalysisReport = '软件（分析）';
const actorCover = '软件（封面）';

/// 界面这一侧、**人真的点出来的**那些改动的写入口。`by` 是 `human`。
///
/// 判据是**这一笔写进去的东西是不是人的判断**：他挑的素材、拖的边界、
/// 改的标签、调的字幕样式、点的「重新分离」。不是「代码跑在界面进程里」。
///
/// 软件自己干的活儿走 [softwareMutation]，别混进来。
///
/// [dataDir] 是改动日志的落点（`<dataDir>/logs/<taskId>.jsonl`），正常接线
/// 由 `main.dart` override 给出。**为 null 时直接抛**：日志漏记一笔，
/// Agent 查到的「什么都没发生」看起来正好像「一切正常」——悄悄少记比
/// 当场炸一下危险得多。测试里 override `dataDirProvider` 就行。
TaskMutation humanMutation({
  required TaskRepository repo,
  required Directory? dataDir,
  required String actor,
}) =>
    _mutation(repo: repo, dataDir: dataDir, by: ActorKind.human, actor: actor);

/// **软件自己干的活儿**的写入口：启动自检、补上次没打完的标、报告分析失败、
/// 抽封面这一类。`by` 是 `agent`。
///
/// **为什么算 agent 而不是 human**——判据是这份日志的用途：
///
/// - 标成 `human`，Agent 读到「人改的」，它会**让步于一个根本不存在的人类
///   决定**：不敢重抽封面、不敢重打标、把软件自愈写的那句失败原因当成人的诊断
/// - 标成 `agent`，Agent 读到的是「我的前作」，它知道这是可以动的东西
///
/// **两种错里前者更危险**，而且把软件自愈标成「人」本身就是报假
/// （`CLAUDE.md`：软件只报事实）。`ActorKind` 只有两个值，第三个值会让
/// Agent 多一类要猜的东西——所以精度交给 [actor] 那一格去承担
/// （`软件（启动自检）` / `软件（补打标）` / …），它本来就是用来说清
/// 「具体是谁」的。
///
/// **配套的一条保险**：软件产出的内容一律不盖 `editedBy` 戳
/// （见 `TaskEdit.stampUnits`）——戳才是「Agent 该不该让步」在数据层的机制，
/// 日志这一格判错也不会让机器切的分镜被当成人手定的。
TaskMutation softwareMutation({
  required TaskRepository repo,
  required Directory? dataDir,
  required String actor,
}) =>
    _mutation(repo: repo, dataDir: dataDir, by: ActorKind.agent, actor: actor);

TaskMutation _mutation({
  required TaskRepository repo,
  required Directory? dataDir,
  required ActorKind by,
  required String actor,
}) {
  if (dataDir == null) {
    throw StateError('数据目录没接线（dataDirProvider 为 null），这次改动没法记进'
        '改动日志，因此不写。测试里请 override dataDirProvider。');
  }
  return TaskMutation(repo: repo, dataDir: dataDir, by: by, actor: actor);
}
