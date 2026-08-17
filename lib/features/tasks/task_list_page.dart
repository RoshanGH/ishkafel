import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme/app_colors.dart';
import '../review/review_page.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../home/help_sheet.dart';
import '../home/readiness_provider.dart';
import '../home/welcome_view.dart';
import '../import_flow/import_exception.dart';
import '../settings/settings_page.dart';
import '../workbench/workbench_page.dart';
import 'new_task_wizard/new_task_wizard.dart';
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
      // `ishkafel review <task>` 进审核页，不进工作台——审核是把关，
      // 不该把人扔进一个能改一切的编辑器
      if (ref.read(initialReviewModeProvider)) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ReviewPage(task: task)),
        );
        return;
      }
      await _openTask(context, ref, task);
    });
  }

  @override
  void dispose() {
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
    final filePath = result.filePath;
    if (filePath == null) {
      // 空白任务：没有原片可导，直接建出来就能编辑
      await ref.read(taskListProvider.notifier).createBlankTask(
            name: '拼片 ${DateTime.now().toString().substring(5, 16)}',
            unitTagGroups: result.unitTagGroups,
            shotTagGroups: result.shotTagGroups,
            unitTagPrompt: result.unitTagPrompt,
            shotTagPrompt: result.shotTagPrompt,
            project: result.project,
          );
      return;
    }
    try {
      await ref.read(taskListProvider.notifier).importFile(
            filePath,
            unitTagGroups: result.unitTagGroups,
            shotTagGroups: result.shotTagGroups,
            unitTagPrompt: result.unitTagPrompt,
            shotTagPrompt: result.shotTagPrompt,
            project: result.project,
          );
    } on ImportException catch (e) {
      // message 已是面向用户的中文提示，直接展示；原始异常只进日志
      AppLog.warn('导入失败 $filePath：${e.cause ?? e.message}');
      if (context.mounted) _showSnackBar(context, e.message);
    } catch (e) {
      AppLog.warn('导入失败 $filePath：$e');
      if (context.mounted) _showSnackBar(context, '导入失败，请稍后重试或更换素材。');
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
    final action = await showTaskCardMenu(context, position);
    if (action == null || !context.mounted) return;
    final controller = ref.read(taskListProvider.notifier);
    switch (action) {
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
        title: const Text('ishkafel',
            style: TextStyle(
                fontSize: AppFontSize.title, fontWeight: FontWeight.w700)),
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
