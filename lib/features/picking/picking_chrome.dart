import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/models/renew_task.dart';
import 'picking_widgets.dart';

/// 阶段②顶栏：返回 + 成片信息 + 三步流程指示（②替换选材激活）
class PickingTopBar extends StatelessWidget implements PreferredSizeWidget {
  final RenewTask task;
  final VoidCallback onBack;

  const PickingTopBar({super.key, required this.task, required this.onBack});

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    final info = task.videoInfo;
    final meta = info == null
        ? task.name
        : '${task.name} · ${info.width}×${info.height} · '
            '${(info.duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
    return Container(
      height: preferredSize.height,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          IconButton(
            key: const Key('picking-back-btn'),
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back,
                color: AppColors.textPrimary, size: 18),
          ),
          Expanded(
            child: Text(
              meta,
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

class _StepIndicator extends StatelessWidget {
  const _StepIndicator();

  @override
  Widget build(BuildContext context) => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepChip(label: '① 切分确认', state: _StepState.done),
          SizedBox(width: AppSpacing.xs),
          _StepChip(label: '② 替换选材', state: _StepState.active),
          SizedBox(width: AppSpacing.xs),
          _StepChip(label: '③ 矩阵导出', state: _StepState.todo),
        ],
      );
}

enum _StepState { done, active, todo }

class _StepChip extends StatelessWidget {
  final String label;
  final _StepState state;

  const _StepChip({required this.label, required this.state});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (state) {
      _StepState.done => (AppColors.surfaceCard, AppColors.green),
      _StepState.active => (
          AppColors.accentBlue.withValues(alpha: 0.18),
          AppColors.accentBlueLight
        ),
      _StepState.todo => (AppColors.surfaceCard, AppColors.textTertiary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(label,
          style: TextStyle(
              fontSize: AppFontSize.caption,
              fontWeight: state == _StepState.active
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: fg)),
    );
  }
}

/// 播放器「原片 ⇄ 候选预览」分段控件。
/// 没勾选候选时候选预览点不动，并说明原因（灰着不解释会被反复点）。
class PreviewSourceSegment extends StatelessWidget {
  final bool candidateEnabled;
  final bool showingCandidate;
  final VoidCallback onOriginal;
  final VoidCallback onCandidate;

  const PreviewSourceSegment({
    super.key,
    required this.candidateEnabled,
    required this.showingCandidate,
    required this.onOriginal,
    required this.onCandidate,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: 240,
          child: PickingSegmented(
            selectedIndex: showingCandidate ? 1 : 0,
            options: [
              SegmentOption(
                key: const Key('picking-preview-original'),
                label: '原片',
                onTap: onOriginal,
              ),
              SegmentOption(
                key: const Key('picking-preview-candidate'),
                label: '候选预览',
                enabled: candidateEnabled,
                onTap: onCandidate,
              ),
            ],
          ),
        ),
        if (!candidateEnabled)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.xs),
            child: Text('勾选一条候选素材后可在此预览',
                style: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: AppFontSize.micro)),
          ),
      ],
    );
  }
}

/// 播放后端降级时的常驻提示条（与阶段①同款：不用一闪而过的 SnackBar）
class PickingPlaybackDegradedBanner extends StatelessWidget {
  const PickingPlaybackDegradedBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('picking-playback-degraded-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      color: AppColors.orange.withValues(alpha: 0.16),
      child: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: AppColors.orange, size: 16),
          SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text('播放器不可用，当前仅可挑选候选素材，无法预览画面',
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

/// 数据不完整（无单元）时的占位页：路由层已拦截，这里是纵深防御
class PickingUnavailableScaffold extends StatelessWidget {
  const PickingUnavailableScaffold({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
            backgroundColor: AppColors.surface, title: const Text('替换选材')),
        body: const Center(
          child: Text('这条任务还没有可替换的台词语义单元，请先完成切分确认',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
      );
}

/// 切换替换模式会丢弃已选候选时的二次确认（破坏性操作）
Future<bool?> showDiscardSelectionDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      title: const Text('切换替换方式会清空已选候选'),
      content: const Text('这个台词语义单元当前已经选好的候选素材会被清空，需要重新挑选。'),
      actions: [
        TextButton(
          key: const Key('picking-discard-cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('picking-discard-confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('清空并切换'),
        ),
      ],
    ),
  );
}
