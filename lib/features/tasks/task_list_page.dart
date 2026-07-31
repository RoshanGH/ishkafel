import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme/app_colors.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../import_flow/import_exception.dart';
import '../workbench/workbench_page.dart';
import 'environment_banner.dart';
import 'source_availability.dart';
import 'task_card.dart';
import 'task_card_menu.dart';
import 'task_list_controller.dart';

class TaskListPage extends ConsumerWidget {
  const TaskListPage({super.key});

  Future<void> _pickAndImport(WidgetRef ref, BuildContext context) async {
    const typeGroup = XTypeGroup(label: '视频', extensions: ['mp4', 'mov']);
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return;
    try {
      await ref.read(taskListProvider.notifier).importFile(file.path);
    } on ImportException catch (e) {
      // message 已是面向用户的中文提示，直接展示；原始异常只进日志
      AppLog.warn('导入失败 ${file.path}：${e.cause ?? e.message}');
      if (context.mounted) _showSnackBar(context, e.message);
    } catch (e) {
      AppLog.warn('导入失败 ${file.path}：$e');
      if (context.mounted) _showSnackBar(context, '导入失败，请稍后重试或更换素材。');
    }
  }

  void _showSnackBar(BuildContext context, String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  /// 源文件缺失的任务 id：探测尚未完成时按「都在」处理，宁可漏报也不误挡入口
  Set<String> _missingSourceTaskIds(WidgetRef ref) =>
      ref.read(missingSourceTaskIdsProvider).valueOrNull ?? const {};

  /// 任务卡点击路由：analysisError 非空（分析失败）优先级最高——不进入审片台，
  /// 只弹出失败原因与「重试」action；其次 `analyzing` 状态或缺少 units（尚未
  /// 完成分析）不响应，只提示「分析中」；`exported`（已导出）已流转到下一
  /// 阶段之外，不再进入审片台（评审 Important 1：路由口径收回到计划范围，
  /// 避免已导出任务被回看入口误导成"可再修改"）；只有待切分确认/选材中
  /// 且 units 非空可进入审片台——选材中为只读回看（WorkbenchPage 内部把
  /// `readOnly` 下发到时间线与检查器，禁用一切会改数据的交互，并禁用
  /// 「确认切分」主按钮）。
  void _openTask(BuildContext context, WidgetRef ref, RenewTask task) {
    // 源文件缺失优先于一切：没有源视频，审片台的播放器、抽帧轨、波形轨全是
    // 空的，重新分析也必定失败——先把原因和补救办法说清楚
    if (_missingSourceTaskIds(ref).contains(task.id)) {
      _showSnackBar(context,
          '「${task.name}」的源文件已不存在，无法预览或重新分析。请把视频文件放回原位后重启应用，或删除该任务重新导入。');
      return;
    }
    if (task.analysisError != null) {
      _showAnalysisFailedSnackBar(context, ref, task);
      return;
    }
    if (task.status == RenewTaskStatus.analyzing || task.units == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('任务分析中，请稍候')));
      return;
    }
    if (task.status == RenewTaskStatus.exported) {
      _showSnackBar(context, '已导出的任务不再支持进入审片台');
      return;
    }
    // 历史遗留数据兜底：帧率非法（旧版本把 ffprobe 的 0/0 解析成 0 后落了库）
    // 时审片台按帧计算会得到 Infinity/整除零而红屏，这里拦在入口
    final fps = task.videoInfo?.fps ?? 0;
    if (fps <= 0 || !fps.isFinite) {
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
        if (name != null) await controller.renameTask(task, name);
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
      }
    } catch (e) {
      AppLog.warn('任务 ${task.id} 重试分析失败：$e');
      if (context.mounted) _showSnackBar(context, '重新分析未能启动，请稍后再试。');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(taskListProvider);
    // 异步探测的结果；探测中沿用上一轮结果，标记不会闪烁
    final missingSources =
        ref.watch(missingSourceTaskIdsProvider).valueOrNull ?? const <String>{};
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('ishkafel',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              onPressed: () => _pickAndImport(ref, context),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新建任务'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const EnvironmentBanners(),
          Expanded(
            child: tasks.when(
              // 重新加载（保存草稿/确认切分等）时继续显示旧列表，只有首次装载
              // 才展示 spinner——否则整页会白屏闪一下
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                  child: Text('加载失败：$e',
                      style: const TextStyle(color: AppColors.textSecondary))),
              data: (list) => list.isEmpty
                  ? const Center(
                      child: Text('还没有任务，点击右上角「新建任务」导入一条成片',
                          style: TextStyle(color: AppColors.textSecondary)))
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 260,
                        childAspectRatio: 0.72,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                      ),
                      itemCount: list.length,
                      itemBuilder: (_, i) => GestureDetector(
                        onTap: () => _openTask(context, ref, list[i]),
                        // macOS 习惯：右键唤出上下文菜单；同时保留卡内「更多」按钮
                        onSecondaryTapUp: (details) => _openCardMenu(
                            context, ref, list[i], details.globalPosition),
                        child: TaskCard(
                          task: list[i],
                          sourceMissing: missingSources.contains(list[i].id),
                          onMenu: (position) =>
                              _openCardMenu(context, ref, list[i], position),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
