import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/models/renew_task.dart';

/// 「返回」时若有未确认的修改，弹窗让用户选择的三种处理方式
enum LeaveAction { cancel, discard, saveDraft }

/// 弹出「有未确认的切分修改」确认对话框，返回用户的选择
/// （对话框被点击外部关闭等情况返回 null，调用方按「取消」处理）
Future<LeaveAction?> showLeaveConfirmDialog(BuildContext context) {
  return showDialog<LeaveAction>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      title: const Text('有未确认的切分修改'),
      content: const Text('离开前请选择如何处理这些修改'),
      actions: [
        TextButton(
          key: const Key('leave-dialog-cancel'),
          onPressed: () => Navigator.of(ctx).pop(LeaveAction.cancel),
          child: const Text('取消'),
        ),
        TextButton(
          key: const Key('leave-dialog-discard'),
          onPressed: () => Navigator.of(ctx).pop(LeaveAction.discard),
          child: const Text('放弃修改'),
        ),
        FilledButton(
          key: const Key('leave-dialog-draft'),
          onPressed: () => Navigator.of(ctx).pop(LeaveAction.saveDraft),
          child: const Text('保存草稿'),
        ),
      ],
    ),
  );
}

/// 审片台顶栏：返回按钮 + 成片信息 + 三步流程指示（阶段①激活）
///
/// 纯展示组件，不持有状态；由 [WorkbenchPage] 传入文案与回调。
class WorkbenchTopBar extends StatelessWidget implements PreferredSizeWidget {
  final RenewTask task;
  final VoidCallback onBack;

  const WorkbenchTopBar({super.key, required this.task, required this.onBack});

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    final info = task.videoInfo;
    final metaText = info == null
        ? task.name
        : '${task.name} · ${info.width}×${info.height} · '
            '${(info.duration.inMilliseconds / 1000).toStringAsFixed(1)}s';

    return Container(
      height: preferredSize.height,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          IconButton(
            key: const Key('workbench-back-btn'),
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary, size: 18),
          ),
          Expanded(
            child: Text(
              metaText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
          ),
          const _StepIndicator(),
        ],
      ),
    );
  }
}

/// 三步流程指示：①切分确认（当前激活）②替换选材 ③导出
class _StepIndicator extends StatelessWidget {
  const _StepIndicator();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: const [
        _StepChip(label: '① 切分确认', active: true),
        SizedBox(width: 6),
        _StepChip(label: '② 替换选材', active: false),
        SizedBox(width: 6),
        _StepChip(label: '③ 导出', active: false),
      ],
    );
  }
}

class _StepChip extends StatelessWidget {
  final String label;
  final bool active;

  const _StepChip({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active
            ? AppColors.accentBlue.withValues(alpha: 0.18)
            : AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          color: active ? AppColors.accentBlueLight : AppColors.textTertiary,
        ),
      ),
    );
  }
}

/// 审片台底部栏：状态摘要 + 「重新 AI 切分」占位（禁用）+ 主按钮「确认切分」
class WorkbenchBottomBar extends StatelessWidget {
  final String summaryText;
  final bool confirmed;
  final VoidCallback? onConfirm;

  const WorkbenchBottomBar({
    super.key,
    required this.summaryText,
    required this.confirmed,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              summaryText,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
          OutlinedButton(
            key: const Key('workbench-reanalyze-btn'),
            onPressed: null,
            child: const Text('重新 AI 切分'),
          ),
          const SizedBox(width: 12),
          FilledButton(
            key: const Key('workbench-confirm-btn'),
            onPressed: confirmed ? null : onConfirm,
            child: Text(confirmed ? '已确认' : '确认切分，进入替换选材'),
          ),
        ],
      ),
    );
  }
}
