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

/// 审片台顶栏：返回按钮 + 成片信息（含标签组）+ 三步流程指示（阶段①激活）
///
/// 纯展示组件，不持有状态；由 [WorkbenchPage] 传入文案与回调。
class WorkbenchTopBar extends StatelessWidget implements PreferredSizeWidget {
  final RenewTask task;
  final VoidCallback onBack;

  const WorkbenchTopBar({super.key, required this.task, required this.onBack});

  /// 有标签组时多出一行；没有的话不留空行（旧任务不该被撑高）
  @override
  Size get preferredSize => Size.fromHeight(_tagGroupText == null ? 52 : 62);

  /// 「标签组 台词语义单元组 / 视觉镜头组」；两个都没选时返回 null。
  /// 只显示名字——把标签组 id 摆到界面上是技术黑话。
  String? get _tagGroupText {
    final names = [
      if (task.unitTagGroup != null) task.unitTagGroup!.name,
      if (task.shotTagGroup != null) task.shotTagGroup!.name,
    ];
    return names.isEmpty ? null : '标签组 ${names.join(' / ')}';
  }

  @override
  Widget build(BuildContext context) {
    final info = task.videoInfo;
    final metaText = info == null
        ? task.name
        : '${task.name} · ${info.width}×${info.height} · '
            '${(info.duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
    final tagGroups = _tagGroupText;

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
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  metaText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: AppFontSize.emphasis,
                      fontWeight: FontWeight.w600),
                ),
                if (tagGroups != null)
                  Text(
                    tagGroups,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: AppFontSize.caption),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 三步流程指示：①切分确认（当前激活）②替换选材 ③导出

/// 工作台底部栏。
///
/// 这里曾经有一个「确认切分，进入替换选材」——它把切分和选材硬拆成两个阶段，
/// 而这两件事本来就是交替进行的（挑着素材发现这刀切得不对，就该直接在时间线
/// 上拖一下）。现在只剩两样东西：**当前事实**与**下一步出口**。
class WorkbenchBottomBar extends StatelessWidget {
  /// 「共 6 个台词语义单元 · 57 个视觉镜头 · 时长 96.2s」这类事实陈述
  final String summaryText;

  /// 当前替换方案能导出多少条；null 表示还没设置任何替换
  final String? combinationText;

  /// 超限等原因导致不能导出时的说明；为 null 表示可以导出
  final String? blockedReason;

  final VoidCallback? onExport;

  const WorkbenchBottomBar({
    super.key,
    required this.summaryText,
    this.combinationText,
    this.blockedReason,
    this.onExport,
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
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(summaryText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: AppFontSize.body)),
                if (combinationText != null || blockedReason != null)
                  Text(
                    blockedReason ?? combinationText!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: blockedReason != null
                            ? AppColors.orange
                            : AppColors.textTertiary,
                        fontSize: AppFontSize.caption),
                  ),
              ],
            ),
          ),
          FilledButton(
            key: const Key('workbench-export-btn'),
            onPressed: blockedReason == null ? onExport : null,
            child: const Text('进入矩阵导出'),
          ),
        ],
      ),
    );
  }
}
