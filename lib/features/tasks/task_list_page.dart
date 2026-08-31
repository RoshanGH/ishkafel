import 'dart:io';
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme/app_colors.dart';
import '../../core/build_mode.dart';
import '../../core/review/review_receipt.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/agent_request.dart';
import '../../core/storage/ui_action.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/storage/tasks_watch.dart';
import '../../core/storage/ui_wake.dart';
import '../review/review_page.dart';
import '../settings/settings_providers.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../home/help_sheet.dart';
import '../home/readiness_provider.dart';
import '../home/welcome_view.dart';
import '../import_flow/import_exception.dart';
import '../settings/settings_page.dart';
import '../director/director_page.dart';
import '../workbench/workbench_page.dart';
import 'new_task_wizard/new_task_wizard.dart';
import 'new_task_wizard/wizard_providers.dart';
import 'environment_banner.dart';
import 'source_availability.dart';
import 'task_card.dart';
import 'task_card_menu.dart';
import 'task_filter.dart';
import 'task_list_toolbar.dart';
import 'task_list_controller.dart';

class TaskListPage extends ConsumerStatefulWidget {
  const TaskListPage({super.key});

  @override
  ConsumerState<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends ConsumerState<TaskListPage> {
  /// 搜索关键词与状态筛选。放在页面本地状态里：它们只影响这一页的呈现，
  /// 不该被写进任何持久化数据，也不必跨页面存活。
  String _query = '';
  TaskFilter _filter = TaskFilter.all;

  /// 应用重新激活时重算源文件存在性缓存。
  ///
  /// 用户常常是「切到 Finder 整理素材 → 切回本应用」，回来时列表上的红标
  /// 必须已经跟上（两个方向都要：删掉的要标出来、放回来的要消掉），
  /// 而不是要求用户重启应用。
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onStateChange: (state) {
      if (state == AppLifecycleState.resumed) {
        ref.invalidate(missingSourceTaskIdsProvider);
      }
    },
  );

  @override
  void initState() {
    super.initState();
    _lifecycle; // 触发 late 初始化，开始监听
    _openInitialTask();
  }

  /// `ishkafel open <task>` 拉起来时，直接落到那个任务的工作台。
  ///
  /// **只跳一次**：跳过之后把标记清掉，否则用户从工作台返回列表会被立刻
  /// 弹回去，等于出不来。
  bool _jumpedToInitialTask = false;

  void _openInitialTask() {
    _startWakeWatcher();
    final id = ref.read(initialTaskIdProvider);
    if (id == null || _jumpedToInitialTask) return;
    _jumpedToInitialTask = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final task = await ref.read(taskRepositoryProvider).findById(id);
      if (!mounted) return;
      if (task == null) {
        _showSnackBar(context, '没有这个任务：$id');
        return;
      }
      await _openTask(context, ref, task);
    });
  }

  /// 轮询 CLI 写的唤醒文件（见 ui_wake.dart）。`open --args` 只在冷启动时
  /// 生效，app 已经在跑时参数被静默丢弃——真机上人从审核页退出后再跑
  /// `ishkafel review`，app 只是亮了一下，什么都没发生。文件冷热启动一条路
  Timer? _wakeTimer;
  bool _handlingWake = false;
  String? _reviewOpenFor;

  /// Agent 在干不属于任何一个任务的活儿（导入、批处理）。
  ///
  /// 有任务的活儿在各模块自己的横幅上说；**没任务的那几秒**只能在这里说——
  /// 不然导入时软件弹出来却一片安静，人不知道它在干什么
  AgentPresence? _globalAgent;

  /// 上一次看到的任务清单指纹。变了就重读列表——**Agent 在外面建的任务、
  /// 改完的任务，界面要自己发现**。此前列表只在进页面那一刻读一次，
  /// CLI 建好的任务在界面上根本不出现，人只能退出去重进
  String? _tasksPrint;

  void _startWakeWatcher() {
    _wakeTimer ??= Timer.periodic(const Duration(milliseconds: 700), (_) {
      _pollWake();
      _pollGlobalAgent();
      _pollTasksChanged();
      _pollUiAction();
    });
    // 冷启动的第一条请求不等第一个周期
    WidgetsBinding.instance.addPostFrameCallback((_) => _pollWake());
  }

  /// Agent 请界面执行一个动作。**界面真的去做**，不是演一遍——
  /// 向导真的弹出来、字段真的填上、创建真的走人走的那条路。
  ///
  /// 演一套写一套的话，两边迟早对不上（这个项目已经栽过三次）
  bool _handlingAction = false;

  /// 这一页起来的时刻。**冷启动后要缓一下再接单**——
  ///
  /// `ui new-task` 会先 `open -a` 把软件拉起来，然后立刻下单。app 冷启动
  /// 时界面 1.5 秒就能起来接单，接着弹向导、建任务、进编导台初始化 mpv，
  /// 而这时 media_kit 的全局状态还没稳：真机连着两次在
  /// `mpv_render_context_create` 里断言失败、整个 app abort
  /// （用户看到的是「ishkafel 意外退出，是否重新打开」）。
  ///
  /// 崩了以后更麻烦：后面所有带 `--visual` 的命令都 exit 5「打不开 app」，
  /// 而手册说 exit 5 别重试——人不在场就是死局。
  ///
  /// 单不会丢，只是晚几秒执行
  final DateTime _pageOpenedAt = DateTime.now();
  static const _warmUp = Duration(seconds: 4);

  void _pollUiAction() {
    if (_handlingAction || !mounted) return;
    if (DateTime.now().difference(_pageOpenedAt) < _warmUp) return;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final req = consumeAgentRequest(dataDir: dataDir, taskId: globalPresenceSlot);
    if (req == null) return;
    _handlingAction = true;
    unawaited(_runUiAction(dataDir, req).whenComplete(() {
      _handlingAction = false;
    }));
  }

  Future<void> _runUiAction(Directory dataDir, AgentRequest req) async {
    void reply(bool ok, String message,
        {Map<String, dynamic> payload = const {}}) {
      writeAgentRequestResult(
          dataDir: dataDir,
          taskId: globalPresenceSlot,
          id: req.id,
          ok: ok,
          message: message,
          payload: payload);
      // **回执一发出就放行下一个动作**，不等这个 Future 走完。
      //
      // 建脚本成片任务那条路会 `await` 进编导台的路由，而它要等**人退出
      // 编导台**才返回——压在 whenComplete 上的话，这把互斥锁就永远不放，
      // 之后每一条可视动作都被静默挡掉，Agent 只能等到超时。
      // （撤场当初躲过了这个坑，见 _runWizardForAgent 里那段注释；
      // 这把锁没躲过——验收 Agent 建完任务紧接着 `ui tasks`，
      // 连着两次白等 90 秒。）
      _handlingAction = false;
    }

    final action = UiAction.parse(req.kind);
    if (action == null) {
      reply(false, '认不出这个动作：${req.kind}');
      return;
    }
    switch (action) {
      case UiAction.wizardOpen:
      case UiAction.wizardFill:
      case UiAction.wizardSubmit:
        // 三步合成一次：向导是个模态对话框，开着的时候拿不到后续请求
        // ——真要一步一停，得把向导拆成非模态的，那是另一件事。
        // 现在的做法是**当着人的面把向导打开、填上、创建**，人看得见
        // 全过程，只是不能在中间插话
        await _runWizardForAgent(dataDir, req, reply);
      case UiAction.wizardCancel:
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        reply(true, '已关掉新建任务');
      case UiAction.tasksOpen:
        // 把压在列表上面的页面全弹掉（工作台/编导台/它们的子页）。
        // 那些页面一退出就松锁，Agent 接着就能写这条任务
        if (mounted) {
          Navigator.of(context).popUntil((r) => r.isFirst);
        }
        reply(true, '已回到任务列表，锁松开了');
      case UiAction.plansApply:
      case UiAction.exportOpen:
        // 这两个动作是给工作台的（它占着那条任务的锁）。列表页收到说明
        // 发错了地方——说清楚，别让 Agent 等到超时
        reply(false, '${action.label}要发给那条任务的工作台，不是任务列表');
    }
  }

  Future<void> _runWizardForAgent(
    Directory dataDir,
    AgentRequest req,
    void Function(bool ok, String message, {Map<String, dynamic> payload})
        reply,
  ) async {
    final p = req.payload;
    final mode = WizardMode.parse('${p['mode']}');
    if (mode == null) {
      reply(false, 'mode 要是 replace / blank / script 之一，给的是 ${p['mode']}');
      return;
    }
    final ids = [
      for (final v in (p['tagGroupIds'] as List? ?? const [])) ?_asInt(v),
    ];
    final filePath = p['filePath'] is String ? p['filePath'] as String : null;
    final issues = validateWizardFill(
        mode: mode, filePath: filePath, tagGroupIds: ids);
    if (issues.isNotEmpty) {
      reply(false, issues.join('；'));
      return;
    }
    if (!mounted) {
      reply(false, '界面已经关了');
      return;
    }
    // 报出在场状态：人看到横幅才知道这一下是 Agent 干的
    writeAgentPresence(
      dataDir: dataDir,
      taskId: globalPresenceSlot,
      presence: AgentPresence(
        holder: 'Agent',
        at: DateTime.now(),
        action: '正在新建任务（${mode.wire}）',
      ),
    );
    try {
      final groups = await _resolveTagGroups(ids);
      if (groups.length != ids.length) {
        reply(false, '这些标签组在当前企业下找不到：'
            '${ids.where((i) => !groups.any((g) => g.id == i)).join('、')}');
        return;
      }
      if (!mounted) {
        reply(false, '界面已经关了');
        return;
      }
      // **真的把向导打开**，字段预填好，让人看见
      final wantName = p['name'] is String ? (p['name'] as String).trim() : '';
      final result = await showNewTaskWizard(
        context,
        prefillUnitGroups: groups,
        prefillShotGroups: groups,
        prefillUnitPrompt: '${p['unitTagPrompt'] ?? ''}',
        prefillShotPrompt: '${p['shotTagPrompt'] ?? ''}',
        autoSubmit: (
          mode: mode.wire,
          filePath: filePath,
        ),
      );
      if (result == null) {
        reply(false, '向导被关掉了（人取消，或者参数不足以创建）');
        return;
      }
      if (!mounted) {
        reply(false, '界面已经关了');
        return;
      }
      // **先回执再进任务**：脚本成片那条路会 await 编导台的路由，
      // 而它要等人退出来才返回——回执压在后面的话，CLI 必然等到超时，
      // 于是「任务建好了但命令报失败」，Agent 照着退出码会去重试、
      // 建出第二个垃圾任务（验收 Agent 实测到的第一个问题）
      // **先建出来拿到 id，再回执**：以前是先回执再建，于是 CLI 只能
      // 去任务库里翻「最新的那条」猜是哪一条——授权框挡住创建时，
      // 猜出来的是上一次的任务，还报「已经建好了」（验收 Agent 撞到）
      //
      // 但也不能等 created 整个跑完：脚本成片那条路会 await 编导台的路由，
      // 要等人退出编导台才返回。所以这里只等「建出来」这一段
      final made = await _createFromWizardHead(ref, context, result,
          name: wantName);
      if (made == null) {
        reply(false, '任务没建成——多半是原片读不到（macOS 可能弹了'
            '「想访问文稿文件夹」的授权框，需要人点允许），或者导入失败了');
        return;
      }
      // 建这一段是异步的，跑完时列表页可能已经不在树上了（人自己退出去了）。
      // 那就只剩「进不进页面」这一件事做不了——**任务是真的建好了，
      // 回执和撤场照发**，否则 Agent 会一直等到超时，最后报一个假的失败
      final created = mounted
          ? _createFromWizardTail(ref, context, result, made)
          : Future<void>.value();
      reply(true, '任务已经建好了',
          payload: {'taskId': made.id, 'kind': made.kind});
      // **撤场要在这儿，不能等 created**：脚本成片那条路会 await 编导台的
      // 路由，而它要等人退出编导台才返回——撤场压在后面的话，播报会一直
      // 停在「正在新建任务」，人看着已经进了编导台却被告知还在建（真机撞到）
      clearAgentPresence(dataDir: dataDir, taskId: globalPresenceSlot);
      await created;
    } catch (e) {
      reply(false, '新建任务失败：$e');
    } finally {
      // 出错的路径同样要撤：上面那次撤过了，再撤一次是幂等的
      clearAgentPresence(dataDir: dataDir, taskId: globalPresenceSlot);
    }
  }

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));

  Future<List<TagGroupRef>> _resolveTagGroups(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final all = await MiaoaTagService().listGroups();
    return [
      for (final g in all)
        if (ids.contains(g.id)) TagGroupRef(id: g.id, name: g.name),
    ];
  }

  /// 盘上的任务清单变了就重读。
  ///
  /// 不是可视模式才需要：静默模式下人回头来看，也该看得到新任务。
  /// 用指纹而不是目录监听——任务落盘走的是「写临时文件再 rename」，
  /// macOS 的目录监听对这种原子替换容易漏事件
  void _pollTasksChanged() {
    if (!mounted) return;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final now = tasksFingerprint(dataDir);
    if (_tasksPrint == null) {
      _tasksPrint = now;
      return;
    }
    if (now == _tasksPrint) return;
    _tasksPrint = now;
    unawaited(ref.read(taskListProvider.notifier).reload());
  }

  void _pollGlobalAgent() {
    if (!mounted) return;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final now =
        readAgentPresence(dataDir: dataDir, taskId: globalPresenceSlot);
    if (now?.action == _globalAgent?.action &&
        (now == null) == (_globalAgent == null)) {
      return;
    }
    setState(() => _globalAgent = now);
    if (now != null && now.step > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        writeAgentAck(
            dataDir: dataDir, taskId: globalPresenceSlot, step: now.step);
      });
    }
  }

  Future<void> _pollWake() async {
    if (_handlingWake || !mounted) return;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final wake = consumeUiWake(dataDir);
    if (wake == null) return;
    _handlingWake = true;
    try {
      final task =
          await ref.read(taskRepositoryProvider).findById(wake.taskId);
      if (!mounted) return;
      if (task == null) {
        _showSnackBar(context, '没有这个任务：${wake.taskId}');
        return;
      }
      // 人可能停在任意页面（编导台/工作台/审核页）：先收回列表再进目标。
      // push 的 await 不能占着 _handlingWake——那会把后续唤醒永远锁在门外
      // （真机撞到过：编导台开着时 `ishkafel open` 毫无反应）
      // Agent 明确说了去哪个模块就照办；没说才按老规矩（review 标志 +
      // 任务类型）。这是全软件导航的落点：人停在任意页面都能被带到目标
      final wantsReview = wake.module == 'review' || (wake.module == null && wake.review);
      if (wake.module == 'director') {
        Navigator.of(context).popUntil((r) => r.isFirst);
        unawaited(Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => DirectorPage(task: task)),
        ));
      } else if (wake.module == 'workbench') {
        Navigator.of(context).popUntil((r) => r.isFirst);
        unawaited(Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => WorkbenchPage(task: task)),
        ));
      } else if (wantsReview) {
        // 同一条任务的审核页已经开着时不再叠一层——Agent 重复跑 review
        // 只该把窗口带到前台
        if (_reviewOpenFor == task.id) return;
        _reviewOpenFor = task.id;
        Navigator.of(context).popUntil((r) => r.isFirst);
        // 审核是把关，不进能改一切的工作台
        unawaited(Navigator.of(context)
            .push(
              MaterialPageRoute(builder: (_) => ReviewPage(task: task)),
            )
            .then((outcome) => _showReviewOutcome(outcome))
            .whenComplete(() => _reviewOpenFor = null));
      } else {
        Navigator.of(context).popUntil((r) => r.isFirst);
        unawaited(_openTask(context, ref, task));
      }
    } finally {
      _handlingWake = false;
    }
  }

  /// 审核回来弹条结果——回到来处继续干活，审核页不是终点站
  void _showReviewOutcome(Object? outcome) {
    if (outcome is! ReviewOutcome || !mounted) return;
    _showSnackBar(context, '审核完成：保留 ${outcome.kept} 条 · 剔除 ${outcome.dropped} 条');
  }

  @override
  void dispose() {
    _wakeTimer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  /// 新建任务：走向导（选来源 + 选两个标签组），确认后才导入并自动分析。
  ///
  /// 标签组必须在建任务时定下来——它既是两层打标的受控词表来源，也是后续
  /// 阶段②「按相同标签检索候选素材」的检索键。
  Future<void> _startNewTask(WidgetRef ref, BuildContext context) async {
    // 用最近一条任务的标签组配置预填（含两层各自的打标约束）：同一个项目里
    // 连着建好几条任务是常态，每次重选四个组、重贴两段约束纯属折磨
    final recent = ref
        .read(taskListProvider)
        .value
        ?.firstWhereOrNull((t) =>
            t.unitTagGroups.isNotEmpty || t.shotTagGroups.isNotEmpty);
    final result = await showNewTaskWizard(
      context,
      prefillUnitGroups: recent?.unitTagGroups ?? const [],
      prefillShotGroups: recent?.shotTagGroups ?? const [],
      prefillUnitPrompt: recent?.unitTagPrompt ?? '',
      prefillShotPrompt: recent?.shotTagPrompt ?? '',
      prefillProject: recent?.project,
    );
    if (result == null) return;
    // 向导是个异步的对话框，关掉的时候列表页可能已经不在了
    if (!context.mounted) return;
    await _createFromWizard(ref, context, result);
  }

  /// 拿到向导结果之后怎么建。**人和 Agent 共用这一段**——
  /// Agent 那条路要是另写一份，两边迟早会不一样（这个项目已经因为
  /// 「同一个东西两处算」栽过三次）
  /// 刚建出来、还没进页面的脚本成片任务
  RenewTask? _pendingDirectorTask;

  /// 建完之后进对应的工作页。脚本成片建出来直接进编导台开写；
  /// 别的两种留在列表上（分析要跑一会儿，人可以先干别的）
  Future<void> _createFromWizardTail(
    WidgetRef ref,
    BuildContext context,
    NewTaskWizardResult result,
    ({String id, String kind}) made,
  ) async {
    final task = _pendingDirectorTask;
    _pendingDirectorTask = null;
    if (made.kind != 'script' || task == null || !context.mounted) return;
    // **先回到列表页再进新任务**。
    //
    // 直接 push 的话，上一个编导台还留在路由栈上活着，新的又建一个
    // ——两个 mpv 渲染上下文并发存在，`mpv_render_context_create`
    // 里的断言当场失败、整个 app abort（真机崩了三次，栈一字不差）。
    //
    // 之前以为是冷启动竞态，加了几秒缓冲；验收 Agent 拿崩溃报告反证：
    // 三次崩溃时 app 已经活了 9 分钟、23 分钟、89 秒，缓冲一次都没
    // 覆盖到。而 `ishkafel open` 那条路一直不崩——它先 popUntil 回
    // 列表页，同一时刻只有一个编导台。差别就在这儿
    Navigator.of(context).popUntil((r) => r.isFirst);
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DirectorPage(task: task)),
    );
    await ref.read(taskListProvider.notifier).reload();
  }

  /// 建任务，**并把建出来的那条报回去**。
  ///
  /// 返回 null = 没建成（导入失败、文件读不到）。以前这里返回 void，
  /// 于是 Agent 那头只能建完去任务库里翻「最新的那条」猜——真机上授权框
  /// 挡住创建、任务压根没建成，猜出来的是上一次的任务，还报「已经建好了」。
  Future<({String id, String kind})?> _createFromWizard(
    WidgetRef ref,
    BuildContext context,
    NewTaskWizardResult result, {
    String name = '',
  }) async {
    final made = await _createFromWizardHead(ref, context, result, name: name);
    // 建好了但页面没了：任务照样是建成的，只是没法再替人进去
    if (made != null && context.mounted) {
      await _createFromWizardTail(ref, context, result, made);
    }
    return made;
  }

  /// 只负责**建出来**，不进页面。
  ///
  /// 与「进页面」拆开是因为 Agent 那条路要**先拿到 id 再回执**：
  /// 进页面那一步会 await 到人退出编导台，回执压在后面的话 CLI 必然超时。
  Future<({String id, String kind})?> _createFromWizardHead(
    WidgetRef ref,
    BuildContext context,
    NewTaskWizardResult result, {
    String name = '',
  }) async {
    if (result.script) {
      // 脚本成片：没有原片、不走分析，建出来直接进编导台开写
      final task = await ref.read(taskListProvider.notifier).createScriptTask(
            name: name.isNotEmpty
                ? name
                : '脚本 ${DateTime.now().toString().substring(5, 16)}',
            unitTagGroups: result.unitTagGroups,
            shotTagGroups: result.shotTagGroups,
            unitTagPrompt: result.unitTagPrompt,
            shotTagPrompt: result.shotTagPrompt,
            project: result.project,
          );
      _pendingDirectorTask = task;
      return (id: task.id, kind: 'script');
    }
    final filePath = result.filePath;
    if (filePath == null) {
      // 空白任务：没有原片可导，直接建出来就能编辑
      final blank = await ref.read(taskListProvider.notifier).createBlankTask(
            name: name.isNotEmpty
                ? name
                : '拼片 ${DateTime.now().toString().substring(5, 16)}',
            unitTagGroups: result.unitTagGroups,
            shotTagGroups: result.shotTagGroups,
            unitTagPrompt: result.unitTagPrompt,
            shotTagPrompt: result.shotTagPrompt,
            project: result.project,
          );
      return (id: blank.id, kind: 'blank');
    }
    try {
      final task = await ref.read(taskListProvider.notifier).importFile(
            filePath,
            unitTagGroups: result.unitTagGroups,
            shotTagGroups: result.shotTagGroups,
            unitTagPrompt: result.unitTagPrompt,
            shotTagPrompt: result.shotTagPrompt,
            project: result.project,
          );
      return task == null ? null : (id: task.id, kind: 'replace');
    } on ImportException catch (e) {
      // message 已是面向用户的中文提示，直接展示；原始异常只进日志
      AppLog.warn('导入失败 $filePath：${e.cause ?? e.message}');
      if (context.mounted) _showSnackBar(context, e.message);
      return null;
    } catch (e) {
      AppLog.warn('导入失败 $filePath：$e');
      if (context.mounted) _showSnackBar(context, '导入失败，请稍后重试或更换素材。');
      return null;
    }
  }

  void _openSettings(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const SettingsPage()));

  void _showSnackBar(BuildContext context, String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  /// 任务卡点击路由：analysisError 非空（分析失败）优先级最高——不进入审片台，
  /// 只弹出失败原因与「重试」action；其次 `analyzing` 状态或缺少 units（尚未
  /// 完成分析）不响应，只提示「分析中」；`exported`（已导出）已流转到下一
  /// 阶段之外，不再进入审片台（评审 Important 1：路由口径收回到计划范围，
  /// 避免已导出任务被回看入口误导成"可再修改"）；只有待切分确认/选材中
  /// 且 units 非空可进入审片台——选材中为只读回看（WorkbenchPage 内部把
  /// `readOnly` 下发到时间线与检查器，禁用一切会改数据的交互，并禁用
  /// 「确认切分」主按钮）。
  Future<void> _openTask(
      BuildContext context, WidgetRef ref, RenewTask task) async {
    // 脚本任务没有原片、不走分析——直接进编导台，下面的检查全不适用
    if (task.isScript) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DirectorPage(task: task)),
      );
      await ref.read(taskListProvider.notifier).reload();
      return;
    }
    // 源文件缺失优先于一切：没有源视频，审片台的播放器、抽帧轨、波形轨全是
    // 空的，重新分析也必定失败——先把原因和补救办法说清楚。
    // 这里做一次实时校验而不是查缓存：缓存可能两个方向都陈旧（见
    // isSourceMissingNow 的注释），一次 stat 只在点击时发生，代价可忽略。
    final missing = await isSourceMissingNow(ref, task);
    if (!context.mounted) return;
    if (missing) {
      _showSnackBar(context,
          '「${task.name}」的源文件已不存在，无法预览或重新分析。请把视频文件放回原位后重试，或删除该任务重新导入。');
      return;
    }
    if (task.analysisError != null) {
      _showAnalysisFailedSnackBar(context, ref, task);
      return;
    }
    // 空白任务不走分析，也没有原片帧率——它进的是同一个工作台，只是内容空着
    if (!task.isBlank &&
        (task.status == RenewTaskStatus.analyzing || task.units == null)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('任务分析中，请稍候')));
      return;
    }
    // 历史遗留数据兜底：帧率非法（旧版本把 ffprobe 的 0/0 解析成 0 后落了库）
    // 时审片台按帧计算会得到 Infinity/整除零而红屏，这里拦在入口
    final fps = task.videoInfo?.fps ?? 0;
    if (!task.isBlank && (fps <= 0 || !fps.isFinite)) {
      _showSnackBar(context, '这条素材缺少可用的帧率信息，无法按帧切分，请重新导入转码后的文件。');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => WorkbenchPage(task: task)),
    );
  }

  /// 任务卡菜单：重命名 / 重新分析 / 删除（删除为破坏性操作，需二次确认）
  Future<void> _openCardMenu(BuildContext context, WidgetRef ref,
      RenewTask task, Offset position) async {
    final action = await showTaskCardMenu(context, position,
        canReview: collectReviewItems(task.replacements ?? const []).isNotEmpty,
        canReanalyze: task.sourcePath != null);
    if (action == null || !context.mounted) return;
    final controller = ref.read(taskListProvider.notifier);
    switch (action) {
      case TaskCardAction.review:
        // 人不靠 CLI 也能进审核页——Agent 挑完但人当时没看，之后随时补审
        if (context.mounted) {
          final outcome = await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ReviewPage(task: task)),
          );
          _showReviewOutcome(outcome);
        }
      case TaskCardAction.rename:
        final name = await promptRenameTask(context, task);
        if (name == null) return;
        final outcome = await controller.renameTask(task, name);
        // 对话框可能停留很久，期间任务被删除时必须给一句反馈而不是静默无事发生
        if (outcome == RenameOutcome.taskMissing && context.mounted) {
          _showSnackBar(context, taskMissingMessage);
        }
      case TaskCardAction.reanalyze:
        await _retryAnalysis(context, ref, task);
      case TaskCardAction.delete:
        if (await confirmDeleteTask(context, task)) {
          await controller.deleteTask(task);
        }
    }
  }

  void _showAnalysisFailedSnackBar(
      BuildContext context, WidgetRef ref, RenewTask task) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('分析失败：${task.analysisError}'),
        action: SnackBarAction(
          label: '重试',
          // 不能丢弃 Future：异常无人接收，用户也看不到任何反馈
          onPressed: () => unawaited(_retryAnalysis(context, ref, task)),
        ),
      ),
    );
  }

  /// 触发重试并把结果翻译成用户看得懂的一句话（静默 return 会让用户以为点击无效）
  Future<void> _retryAnalysis(
      BuildContext context, WidgetRef ref, RenewTask task) async {
    try {
      final outcome =
          await ref.read(taskListProvider.notifier).retryAnalysis(task);
      if (!context.mounted) return;
      switch (outcome) {
        case RetryOutcome.started:
          _showSnackBar(context, '已开始重新分析「${task.name}」');
        case RetryOutcome.alreadyRunning:
          _showSnackBar(context, '该任务正在分析中，请稍候');
        case RetryOutcome.pipelineUnavailable:
          _showSnackBar(context, pipelineUnavailableMessage);
        case RetryOutcome.taskMissing:
          _showSnackBar(context, taskMissingMessage);
      }
    } catch (e) {
      AppLog.warn('任务 ${task.id} 重试分析失败：$e');
      if (context.mounted) _showSnackBar(context, '重新分析未能启动，请稍后再试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(taskListProvider);
    // 异步探测的结果；探测中沿用上一轮结果，标记不会闪烁
    final missingSources =
        ref.watch(missingSourceTaskIdsProvider).valueOrNull ?? const <String>{};
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('ishkafel',
              style: TextStyle(
                  fontSize: AppFontSize.title, fontWeight: FontWeight.w700)),
          // 调试构建必须自报家门：它不带凭据和 CLI，被误当正式版用过两次，
          // 用户以为软件坏了
          if (isDebugBuild)
            Container(
              key: const Key('debug-build-badge'),
              margin: const EdgeInsets.only(left: AppSpacing.sm),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.orange.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('开发调试版',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.orange,
                      fontWeight: FontWeight.w600)),
            ),
        ]),
        actions: [
          // 常驻入口：忘掉流程的时刻，恰恰是列表里已经堆了一屏任务的时候，
          // 只在空状态露一次脸的说明等于没有
          IconButton(
            key: const Key('task-list-help'),
            tooltip: '使用说明',
            icon: const Icon(Icons.help_outline, size: 18),
            onPressed: () => showHelpSheet(context),
          ),
          IconButton(
            key: const Key('task-list-settings'),
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined, size: 18),
            onPressed: () => _openSettings(context),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              onPressed: () => _startNewTask(ref, context),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新建任务'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const EnvironmentBanners(),
          // Agent 在干没有任务归属的活儿（导入）：这几秒里界面必须说话
          if (_globalAgent != null)
            NoticeBanner(
              key: const Key('global-agent-banner'),
              icon: Icons.smart_toy_outlined,
              color: AppColors.accentBlue,
              message: _globalAgent!.action.isEmpty
                  ? '${_globalAgent!.holder} 正在操作'
                  : _globalAgent!.action,
            ),
          // 刷新失败但旧列表还在：不清空网格，只在顶部挂一条可重试的提示
          if (tasks.hasError && tasks.valueOrNull != null)
            NoticeBanner(
              icon: Icons.sync_problem,
              color: AppColors.orange,
              message: taskLoadFailedMessage,
              actionLabel: '重试',
              onAction: () => _reload(ref),
            ),
          Expanded(child: _buildTasksArea(context, ref, tasks, missingSources)),
        ],
      ),
    );
  }

  /// 三态：有数据就渲染网格（哪怕本次刷新失败）；无数据且出错给可重试的
  /// 中文提示；否则只有首次装载会看到 spinner
  Widget _buildTasksArea(BuildContext context, WidgetRef ref,
      AsyncValue<List<RenewTask>> tasks, Set<String> missingSources) {
    final list = tasks.valueOrNull;
    if (list == null) {
      return tasks.hasError
          ? _LoadErrorView(onRetry: () => _reload(ref))
          : const Center(child: CircularProgressIndicator());
    }
    if (list.isEmpty) {
      // 首屏是产品的门面：本应用靠「把 .app 交给同事双击打开」分发，
      // 一行灰字既不说这是什么，也不说要先准备什么
      return WelcomeView(
        readiness: ref.watch(readinessProvider),
        onStart: () => _startNewTask(ref, context),
        onOpenSettings: () => _openSettings(context),
      );
    }
    final visible =
        applyTaskFilter(list, query: _query, filter: _filter);
    return Column(
      children: [
        TaskListToolbar(
          query: _query,
          filter: _filter,
          counts: {
            for (final f in TaskFilter.values)
              f: list.where(f.matches).length,
          },
          onQueryChanged: (q) => setState(() => _query = q),
          onFilterChanged: (f) => setState(() => _filter = f),
        ),
        Expanded(
          child: visible.isEmpty
              ? NoMatchView(
                  query: _query,
                  filter: _filter,
                  onReset: () => setState(() {
                    _query = '';
                    _filter = TaskFilter.all;
                  }),
                )
              : _grid(context, ref, visible, missingSources),
        ),
      ],
    );
  }

  Widget _grid(BuildContext context, WidgetRef ref, List<RenewTask> list,
      Set<String> missingSources) {
    return GridView.builder(
      padding: const EdgeInsets.all(AppSpacing.lg),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        childAspectRatio: 0.72,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) => GestureDetector(
        onTap: () => _openTask(context, ref, list[i]),
        // macOS 习惯：右键唤出上下文菜单；同时保留卡内「更多」按钮
        onSecondaryTapUp: (details) =>
            _openCardMenu(context, ref, list[i], details.globalPosition),
        child: TaskCard(
          task: list[i],
          sourceMissing: missingSources.contains(list[i].id),
          onMenu: (position) => _openCardMenu(context, ref, list[i], position),
        ),
      ),
    );
  }

  /// 重新装载：失败会再次落进 state，由上面的提示继续兜住（不能丢弃 Future）
  void _reload(WidgetRef ref) =>
      unawaited(ref.read(taskListProvider.notifier).reload());
}

/// 首次装载失败的整页态：一句中文说明 + 一个真的能再试一次的按钮。
///
/// 原来这里是 `Text('加载失败：$e')`——把异常类名与 errno 摊给用户，
/// 而且没有任何重试入口，用户只能重启应用。
class _LoadErrorView extends StatelessWidget {
  final VoidCallback onRetry;

  const _LoadErrorView({required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_off_outlined,
                size: AppSpacing.xxl, color: AppColors.textSecondary),
            const SizedBox(height: AppSpacing.md),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: Text(taskLoadFailedMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: AppFontSize.emphasis,
                      height: 1.5,
                      color: AppColors.textSecondary)),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      );
}
