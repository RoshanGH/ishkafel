import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';
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

/// 播放后端降级（如构造真实播放器失败）时的常驻提示条（橙色系语义色）。
///
/// 用常驻 banner 而非一次性 SnackBar：一是不依赖计时器（widget 测试里更好
/// 断言，不用担心自动消失的时序问题），二是审片台一旦进入无播放模式会
/// 持续影响体验，用户应该随时能看到原因，而不是错过一闪而过的提示。
class PlaybackDegradedBanner extends StatelessWidget {
  const PlaybackDegradedBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('playback-degraded-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.orange.withValues(alpha: 0.16),
      child: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: AppColors.orange, size: 16),
          SizedBox(width: 8),
          Expanded(
            child: Text('播放器不可用，当前仅可编辑切分',
                style: TextStyle(
                    color: AppColors.orange,
                    fontSize: AppFontSize.body,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
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
                  fontSize: AppFontSize.emphasis,
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
          fontSize: AppFontSize.caption,
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
              style: const TextStyle(color: AppColors.textSecondary, fontSize: AppFontSize.body),
            ),
          ),
          // 该能力尚未接通（重新分析会丢弃当前所有人工调整，需先设计二次确认
          // 与进度反馈）。在接通前也不能留一个点不动、没有任何解释的灰按钮——
          // 用户只会反复点它并怀疑软件坏了，违反「主操作有明确反馈」的标准。
          Tooltip(
            message: '此功能尚未开放。重新切分会丢弃当前所有人工调整，正在设计确认流程',
            child: OutlinedButton(
              key: const Key('workbench-reanalyze-btn'),
              onPressed: null,
              child: const Text('重新 AI 切分'),
            ),
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
