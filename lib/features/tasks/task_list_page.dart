import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme/app_colors.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../import_flow/import_exception.dart';
import '../workbench/workbench_page.dart';
import 'environment_banner.dart';
import 'task_card.dart';
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

  /// 任务卡点击路由：analysisError 非空（分析失败）优先级最高——不进入审片台，
  /// 只弹出失败原因与「重试」action；其次 `analyzing` 状态或缺少 units（尚未
  /// 完成分析）不响应，只提示「分析中」；`exported`（已导出）已流转到下一
  /// 阶段之外，不再进入审片台（评审 Important 1：路由口径收回到计划范围，
  /// 避免已导出任务被回看入口误导成"可再修改"）；只有待切分确认/选材中
  /// 且 units 非空可进入审片台——选材中为只读回看（WorkbenchPage 内部把
  /// `readOnly` 下发到时间线与检查器，禁用一切会改数据的交互，并禁用
  /// 「确认切分」主按钮）。
  void _openTask(BuildContext context, WidgetRef ref, RenewTask task) {
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

  void _showAnalysisFailedSnackBar(
      BuildContext context, WidgetRef ref, RenewTask task) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('分析失败：${task.analysisError}'),
        action: SnackBarAction(
          label: '重试',
          onPressed: () =>
              ref.read(taskListProvider.notifier).retryAnalysis(task),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(taskListProvider);
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
                        child: TaskCard(task: list[i]),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
