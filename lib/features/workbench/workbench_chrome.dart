import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';
import '../../core/models/renew_task.dart';
import '../tasks/task_id_badge.dart';

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
/// 「正在重新打标」的进行条。
///
/// 重打要走两趟云端推理，几秒到几十秒。没有这条，用户点完「是」界面上
/// 什么都不会变，只会以为软件没反应而反复去点。
class RetaggingBanner extends StatelessWidget {
  final int unitCount;
  const RetaggingBanner({super.key, required this.unitCount});

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('retagging-banner'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: AppColors.accentBlue.withValues(alpha: 0.16),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.accentBlueLight),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('正在为 $unitCount 个台词语义单元重新打标，可以继续编辑',
                  style: const TextStyle(
                      color: AppColors.accentBlueLight,
                      fontSize: AppFontSize.body,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
}

/// 「正在生成配音」的进度条。
///
/// 每句要走一次音频理解 + 一到两次合成，十句就是一分多钟。没有进度条，
/// 用户只会以为点了没反应。
class VoiceGeneratingBanner extends StatelessWidget {
  final int done;
  final int total;
  const VoiceGeneratingBanner(
      {super.key, required this.done, required this.total});

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('voice-generating-banner'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: AppColors.green.withValues(alpha: 0.16),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.green),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('正在生成配音 $done / $total 句，可以继续编辑',
                  style: const TextStyle(
                      color: AppColors.green,
                      fontSize: AppFontSize.body,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
}

/// 预览音轨的状态条：正在合成 / 合不出来。
///
/// 不写出来的话，用户不知道自己听到的到底是原声还是成品——而这正是预览
/// 要回答的唯一问题。
class PreviewAudioBanner extends StatelessWidget {
  final String text;
  final bool building;

  /// 重新合成一次。取不到配乐最常见的原因是网络抖动或登录过期——那不是
  /// 用户的问题，不该逼他去重选一首曲子。为空表示这条提示没有重试出口
  final VoidCallback? onRetry;

  const PreviewAudioBanner(
      {super.key,
      required this.text,
      required this.building,
      this.onRetry});

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('preview-audio-banner'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: (building ? AppColors.accentBlue : AppColors.orange)
            .withValues(alpha: 0.16),
        child: Row(
          children: [
            if (building) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.accentBlue),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: building ? AppColors.accentBlue : AppColors.orange,
                      fontSize: AppFontSize.body,
                      fontWeight: FontWeight.w600)),
            ),
            if (onRetry != null && !building)
              TextButton(
                key: const Key('preview-audio-retry'),
                onPressed: onRetry,
                style: TextButton.styleFrom(
                    foregroundColor: AppColors.orange,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('重试'),
              ),
          ],
        ),
      );
}

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

  /// 打开「标签组设置」。标签组本来只在新建向导里选一次，选漏了就再也改不
  /// 了——那条任务从此打不出标签，候选检索的主路径永远用不上。
  final VoidCallback? onEditTagGroups;

  /// 打开「字幕样式」。**遇到自带烧录字幕的素材只能靠它**：默认的白字黑描边
  /// 盖不住，原字幕会从描边缝里透出来，成片上两行字打架；切成底条或毛玻璃
  /// 才能盖住。以前这条线连改都改不了
  final VoidCallback? onEditSubtitle;

  const WorkbenchTopBar({
    super.key,
    required this.task,
    required this.onBack,
    this.onEditTagGroups,
    this.onEditSubtitle,
  });

  /// 有标签组时多出一行；没有的话不留空行（旧任务不该被撑高）
  @override
  Size get preferredSize => Size.fromHeight(_tagGroupText == null ? 52 : 62);

  /// 「标签组 台词语义单元组 / 视觉镜头组」。
  ///
  /// 一个都没选时也要说出来——什么都不显示，用户只会以为这条任务本来就不用
  /// 标签，而实际上是打标和标签检索都被悄悄跳过了。
  String? get _tagGroupText {
    final names = [
      for (final g in task.unitTagGroups) g.name,
      for (final g in task.shotTagGroups) g.name,
    ];
    return names.isEmpty ? '未设置标签组，不会打标' : '标签组 ${names.join(' / ')}';
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
          // 进到任务里也要一眼看见自己在第几号任务上——人跟 Agent 报的
          // 就是这个号
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TaskIdBadge(task: task),
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
          if (onEditSubtitle != null)
            TextButton.icon(
              key: const Key('workbench-subtitle-style-btn'),
              onPressed: onEditSubtitle,
              icon: const Icon(Icons.closed_caption_outlined, size: 15),
              label: const Text('字幕'),
              style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary),
            ),
          if (onEditTagGroups != null)
            TextButton.icon(
              key: const Key('workbench-tag-groups-btn'),
              onPressed: onEditTagGroups,
              icon: const Icon(Icons.sell_outlined, size: 15),
              label: const Text('标签组'),
              style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }
}

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

  /// 有已挑候选时出现：人的审核主入口。为 null 不显示
  final VoidCallback? onReview;

  /// 写成一份剪映工程，去剪映里接着改。为 null 表示正在生成、或还没得可导
  final VoidCallback? onJianying;

  /// 有几句指定了新音色。为 0 时不显示「生成配音」——没选音色的片子
  /// 生成个什么
  final int voiceCount;

  /// 点「生成配音」。为 null 表示正在生成、或这条任务已只读。
  final VoidCallback? onGenerateVoices;

  const WorkbenchBottomBar({
    super.key,
    required this.summaryText,
    this.combinationText,
    this.blockedReason,
    this.onExport,
    this.onReview,
    this.onJianying,
    this.voiceCount = 0,
    this.onGenerateVoices,
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
          if (voiceCount > 0) ...[
            OutlinedButton.icon(
              key: const Key('workbench-generate-voices-btn'),
              onPressed: onGenerateVoices,
              icon: const Icon(Icons.graphic_eq, size: 16),
              label: Text('生成配音（$voiceCount 句）'),
            ),
            const SizedBox(width: 8),
          ],
          if (onReview != null) ...[
            OutlinedButton(
              key: const Key('workbench-review-btn'),
              onPressed: onReview,
              child: const Text('审核候选'),
            ),
            const SizedBox(width: 8),
          ],
          // 剪映是**另一个出口**，不是导出的一种格式：导出出的是定死的成片，
          // 剪映拿到的是还没定死的选择——所有候选摞成多条轨，人在那边边看边切
          OutlinedButton(
            key: const Key('workbench-jianying-btn'),
            onPressed: onJianying,
            child: const Text('剪映'),
          ),
          const SizedBox(width: 8),
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
