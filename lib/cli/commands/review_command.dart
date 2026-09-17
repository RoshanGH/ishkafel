import 'dart:convert';
import '../../core/models/semantic_unit.dart';
import 'dart:io';

import '../../core/models/renew_task.dart';
import '../../core/review/review_receipt.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/agent_request.dart';
import '../../core/storage/ui_wake.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_log.dart';
import '../../core/storage/task_mutation.dart';
import '../../core/storage/task_seq.dart';
import '../agent_stage.dart';
import '../app_locator.dart';
import '../agent_lock_holder.dart';
import '../cli_output.dart';
import '../delegate.dart';
import '../gui_lock_guidance.dart';
import '../review_apply.dart';

/// `ishkafel review <task>` —— 把 app 拉起来进**审核模式**，人过一遍
/// 挑好的候选、勾选去留、确认。
///
/// `ishkafel review list|drop|keep <task>` —— **人在审片台看着，让 Agent
/// 动手**。审片台是人做决定的地方，但做决定不等于自己点：人说「第 3、7、
/// 12 条删掉」，它去删，人看着卡片一张张变。
///
/// 剔除逻辑是固定的、播放的是本地落好的素材（看到的就是要交付的），所以
/// 审核界面由软件提供而不是 Agent 现造。
///
/// **审核完一切回到主流程**：剔除落进任务，`ishkafel task <id>` 里的方案
/// 就是最终结果——没有回执要取。人确认没确认由人告诉你；等不等、等多久是
/// 你和用户之间的策略，软件不当流程裁判。
Future<int> runReviewCommand({
  required List<String> rest,
  required Directory dataDir,
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,

  /// 测试注入：app 在不在。真机走默认（看目录存不存在）
  bool Function(String path)? appExists,

  /// `drop` / `keep` 要动的候选：`单元:镜头:素材`，逗号分隔
  String? items,

  /// 一整份决定（`{"decisions": [...]}`），给批量改用
  String? file,
  String? holder,
  bool? visual,

  /// 界面在这条任务上时等它代办多久——委派是首选路径，不是必经之路，
  /// 秒级兜底就好（见 delegate.dart）。没应不算失败：自己直写顶上
  Duration waitForUi = const Duration(seconds: 2),
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel review <任务 id>            打开审核界面给人看\n'
        '      ishkafel review list <任务 id>       列出待审候选（带编号）\n'
        '      ishkafel review drop <任务 id> --items 0:-:100,1:2:202\n'
        '      ishkafel review keep <任务 id> --items 0:-:100');
    return exitBadUsage;
  }
  const actions = ['list', 'drop', 'keep'];
  final isAction = actions.contains(rest.first) && rest.length >= 2;
  final id = isAction ? rest[1] : rest.first;

  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  final candidates =
      collectReviewItems(task.replacementsFor(task.units ?? const []));

  if (!isAction) {
    return _openReviewUi(
        task: task, items: candidates, dataDir: dataDir, run: run,
        env: env, appExists: appExists, sink: sink);
  }
  if (rest.first == 'list') {
    // **审核正是最需要信息的地方**：人在审片台上看得到画面、能悬停播放、
    // 一眼看出「这条烧着字」；Agent 一度只拿到一个数字，不知道它叫什么、
    // 画面是什么、烧没烧字、什么牌子。人说「第 3 条删掉」它能删，
    // 人问「第 3 条是什么」它答不上来——而这些 task --json 里全都有，
    // 同一份数据换个地方就没了
    final byId = {for (final m in task.pickedMaterials) m.id: m};
    emitJson({
      'taskId': task.id,
      'total': candidates.length,
      'items': [
        for (final i in candidates)
          {
            // 编号原样能喂回 --items，不用调用方自己拼
            'ref': '${i.unit}:${i.shot ?? '-'}:${i.material}',
            'unit': i.unit,
            'shot': i.shot,
            'material': i.material,
            if (byId[i.material] case final m?) ...{
              'name': m.name,
              if (m.voiceover.isNotEmpty) 'voiceover': m.voiceover,
              if (m.sceneDescription.isNotEmpty)
                'sceneDescription': m.sceneDescription,
              if (m.durationMs != null) 'durationMs': m.durationMs,
              // 会毁掉整片的那两条，审核这一步尤其该看见
              if (m.burnedText != null) 'burnedText': m.burnedText,
              if (m.productBrand != null) 'productBrand': m.productBrand,
              if (m.framesSeen != null) 'framesSeen': m.framesSeen,
            },
          },
      ],
    }, out: out);
    return 0;
  }
  return _changeCandidates(
    task: task,
    candidates: candidates,
    keep: rest.first == 'keep',
    items: items,
    file: file,
    dataDir: dataDir,
    repository: repository,
    holder: holder ?? agentLockHolder,
    visual: visual,
    waitForUi: waitForUi,
    out: out,
    sink: sink,
  );
}

/// 打开审核界面：意图走唤醒文件（见 ui_wake.dart）——`--args` 只在冷启动
/// 生效，app 已经在跑时会被静默丢弃
Future<int> _openReviewUi({
  required RenewTask task,
  required List<ReviewItem> items,
  required Directory dataDir,
  required Future<ProcessResult> Function(String, List<String>)? run,
  required Map<String, String>? env,
  required bool Function(String path)? appExists,
  required StringSink sink,
}) async {
  if (items.isEmpty) {
    // 没有候选就没有可审的——拉起一个空审核页只会让人困惑
    sink.writeln('${task.id} 还没有挑过任何候选，没有可审核的。'
        '先 apply plans 或在 candidates 里挑，再来审核');
    return exitBadUsage;
  }
  writeUiWake(dataDir, task.id, review: true, module: 'review');
  final failure =
      await launchApp(run: run ?? Process.run, env: env, exists: appExists);
  if (failure != null) {
    sink.writeln(failure);
    return exitEnv;
  }
  sink.writeln('审核界面已打开（${items.length} 条候选待审）。'
      '等用户告诉你继续；确认后 ishkafel task ${task.id} 里的方案就是审核后的最终结果');
  return 0;
}

/// 剔除 / 恢复。顺序与 `script apply` 一致：**校验 → 拿锁 → 重读任务 →
/// 再校验一次 → 写入 → 放锁**。第二次校验不是多余的：拿锁期间人可能在
/// 界面上自己点掉了几条，第一次校验时成立的前提可能已经不成立
Future<int> _changeCandidates({
  required RenewTask task,
  required List<ReviewItem> candidates,
  required bool keep,
  required String? items,
  required String? file,
  required Directory dataDir,
  required FileTaskRepository repository,
  required String holder,
  required bool? visual,
  required Duration waitForUi,
  required StringSink? out,
  required StringSink sink,
}) async {
  final what = keep ? '恢复' : '剔除';
  final List<ReviewDecision> decisions;
  if (file != null) {
    try {
      final raw = jsonDecode(File(file).readAsStringSync());
      final list = raw is Map ? raw['decisions'] : raw;
      decisions = [
        for (final d in (list as List)) ?ReviewDecision.tryFromJson(d),
      ];
    } catch (e) {
      sink.writeln('读不懂 $file（要求 {"decisions": [...]}）：$e');
      return exitBadUsage;
    }
  } else if ((items ?? '').trim().isEmpty) {
    sink.writeln('没说要$what哪几条。用 --items 单元:镜头:素材（逗号分隔），'
        '整体替换的候选镜头位写 `-`，例如 --items 0:-:100,1:2:202。'
        '编号可以从 ishkafel review list ${task.id} 拿');
    return exitBadUsage;
  } else {
    final parsed = parseReviewItems(items!, keep: keep);
    if (parsed.issues.isNotEmpty) {
      _reject(parsed.issues, sink);
      return exitBadUsage;
    }
    decisions = parsed.decisions;
  }

  // 先在锁外面校验一遍：不合格就别去打扰正在用界面的人
  final first =
      validateReviewSubmission(items: candidates, decisions: decisions);
  if (first.isNotEmpty) {
    _reject(first, sink);
    return exitBadUsage;
  }

  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!lock.acquire(holder)) {
    final current = lock.read();
    // 界面占着 ≠ 冲突：人正开着审片台看着指挥你，那就把活儿交给界面去做。
    // 它剔掉的卡是界面里的临时状态，人按「确认」才落盘——你自己写盘会让
    // 人还没确认盘上就变了
    if (isGuiHolder(current?.holder)) {
      return _delegateToUi(
        taskId: task.id,
        task: task,
        decisions: decisions,
        keep: keep,
        dataDir: dataDir,
        repository: repository,
        out: out,
        sink: sink,
        waitFor: waitForUi,
      );
    }
    sink.writeln(guiLockGuidance(
        holder: current?.holder, taskId: task.id));
    return exitLocked;
  }
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder,
  );
  try {
    // 一条一条地走：人看的是过程——那张卡滚进视野、变成已剔除，再下一张
    for (var n = 0; n < decisions.length; n++) {
      final d = decisions[n];
      final action = '正在$what第 ${d.unit + 1} 段'
          '${d.shot == null ? '' : '第 ${d.shot! + 1} 镜'}的素材 ${d.material}'
          '（${n + 1}/${decisions.length}）';
      final focus = AgentFocus(
        module: 'review',
        lineIndex: d.unit,
        unitIndex: d.unit,
        shotIndex: d.shot,
        materialId: d.material,
      );
      if (n == 0) {
        await stage.begin(action, focus: focus);
      } else {
        await stage.show(action, focus: focus);
      }
      // 静默模式下 begin/show 什么都不做，在场状态还是要写：
      // 人可能正开着这一页，至少该知道有东西在动他的任务
      if (!stage.visual) stage.note(action, focus: focus);
    }

    return await _commitReviewDecisions(
      task: task,
      decisions: decisions,
      keep: keep,
      dataDir: dataDir,
      repository: repository,
      sink: sink,
      out: out,
    );
  } finally {
    stage.end();
    // 静默模式下 heartbeat 不写文件，但保险起见一并撤掉
    clearAgentPresence(dataDir: dataDir, taskId: task.id);
    lock.release(holder);
  }
}

/// 落盘剔除/恢复决定：**有锁时的直写**（`_changeCandidates`）和**委派
/// 没跟上时的自己动手**（`_delegateToUi` 的 `myself`）共用同一份——
/// 避免同一件事两处算
Future<int> _commitReviewDecisions({
  required RenewTask task,
  required List<ReviewDecision> decisions,
  required bool keep,
  required Directory dataDir,
  required FileTaskRepository repository,
  required StringSink sink,
  required StringSink? out,
}) async {
  RenewTask? updated;
  try {
    updated = await TaskMutation(
      repo: repository,
      dataDir: dataDir,
      by: ActorKind.agent,
      actor: 'Agent',
    ).apply(
      taskId: task.id,
      op: 'review.prune',
      where: {
        'decisions': [
          for (final d in decisions) {'unit': d.unit, 'shot': d.shot, 'material': d.material},
        ],
      },
      // 拿锁期间人可能自己点过：edit 拿到的 fresh 就是重读过的那一份，
      // 校验也要在这份新鲜数据上重来一遍，别拿旧前提写新数据。
      // 校验没过就抛出去——没落盘就不该记日志，edit 必须是纯的，
      // 用抛异常而不是改外层变量来带出「拒绝」这个结果
      edit: (fresh) {
        final freshUnits = fresh.units ?? const <SemanticUnit>[];
        final freshItems = collectReviewItems(fresh.replacementsFor(freshUnits));
        final second =
            validateReviewSubmission(items: freshItems, decisions: decisions);
        if (second.isNotEmpty) throw _ReviewRejected(second);
        final pruned =
            applyReviewDecisions(fresh.replacementsFor(freshUnits), decisions);
        final materials = {for (final m in fresh.pickedMaterials) m.id: m};
        return TaskEdit(
          task: fresh.copyWith(replacementsByUid: RenewTask.byUid(freshUnits, pruned)),
          before: {
            'decisions': [for (final d in decisions) reviewDecisionFacts(d, materials)],
          },
          after: {'left': collectReviewItems(pruned).length},
        );
      },
    );
  } on _ReviewRejected catch (e) {
    sink.writeln('（拿到锁之后重新核对，这些不再成立——多半是有人在界面里改过）');
    _reject(e.problems, sink);
    return exitBadUsage;
  }
  if (updated == null) {
    sink.writeln('任务在写入前被删了：${task.id}');
    return exitNotFound;
  }
  emitJson({
    'ok': true,
    'taskId': task.id,
    if (keep) 'kept': decisions.length else 'dropped': decisions.length,
    'left': collectReviewItems(updated.replacementsFor(updated.units ?? const [])).length,
  }, out: out);
  return 0;
}

/// 把剔除/恢复交给正开着的界面去做——**委派是首选路径，不是必经之路**
/// （见 `delegate.dart`）。界面确实停在这条任务上才试；接了单但没应，
/// 或者压根不在这条任务上，就自己直写，不等它。
///
/// 界面接单成功时**回报要说清它还没落盘**：人得自己按确认，这不是啰嗦
/// ——Agent 报一句「已剔除」，人以为完事了，实际关掉窗口就白干了。
/// 但这只在**界面真的应了**的时候成立：没应、或者界面不在场，
/// 就没有「等人确认」这回事——自己直写才是老实的，不能假装还在等谁
Future<int> _delegateToUi({
  required String taskId,
  required RenewTask task,
  required List<ReviewDecision> decisions,
  required bool keep,
  required Directory dataDir,
  required FileTaskRepository repository,
  required StringSink? out,
  required StringSink sink,
  required Duration waitFor,
}) async {
  return delegateOrDoItYourself<int>(
    dataDir: dataDir,
    taskId: taskId,
    timeout: waitFor,
    viaUi: () async {
      final id = writeAgentRequest(
        dataDir: dataDir,
        taskId: taskId,
        kind: keep ? 'review.keep' : 'review.drop',
        payload: {'decisions': [for (final d in decisions) d.toJson()]},
      );
      final result =
          await waitForAgentRequest(dataDir: dataDir, taskId: taskId, id: id);
      if (result == null) return null; // 没应，交给自己直写
      if (!result.ok) {
        // 界面**真的答复了**、只是没做成——不是「没应」，不兜底，
        // 原样把拒绝理由带回去
        sink.writeln('界面没做成：${result.message}');
        return exitBadUsage;
      }
      emitJson({
        'ok': true,
        'taskId': taskId,
        'delegated': true,
        if (keep) 'kept': decisions.length else 'dropped': decisions.length,
        'message': result.message,
        // 说清这一步还没落盘——人不按确认就等于没改
        'next': '已经在界面上标好了，等用户按「确认」才会落进任务',
      }, out: out);
      return 0;
    },
    myself: () async {
      sink.writeln('界面不在这条任务上（或没跟上），直接自己'
          '${keep ? '恢复' : '剔除'}…');
      return _commitReviewDecisions(
        task: task,
        decisions: decisions,
        keep: keep,
        dataDir: dataDir,
        repository: repository,
        sink: sink,
        out: out,
      );
    },
  );
}

void _reject(List<String> issues, StringSink sink) {
  sink.writeln('这一批没有落盘（整批拒绝，下面是全部问题）：');
  for (final i in issues) {
    sink.writeln('· $i');
  }
}

/// 拿到锁之后重新核对没通过——从 edit 闭包里抛出来，让 TaskMutation 不落盘
/// 也不记日志（edit 必须是纯的，不能靠改外层变量带出「拒绝」这个结果）
class _ReviewRejected implements Exception {
  final List<String> problems;
  const _ReviewRejected(this.problems);
}

/// 一条剔除/保留决定值得记进日志的事实：不是只记素材 id，
/// 是这条素材的标签、画面描述、烧字、品牌——Agent 要能从这些看出
/// 人剔除的是哪一类，即便人没说为什么
