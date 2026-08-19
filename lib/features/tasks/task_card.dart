import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/analysis/analysis_progress.dart';
import '../../core/models/renew_task.dart';
import 'analysis_progress_store.dart';
import 'task_card_hint.dart';
import 'task_metrics.dart';
import 'source_availability.dart';

/// 状态徽标文案与配色。
///
/// **可编辑不是一个状态，是常态**——一个永远不会结束的「编辑中」写在卡片上
/// 只是噪音（用户原话：「编辑中这个状态有没有结束那一刻呢？如果没有的话，
/// 那就不用写出来了吧？」）。所以只有真的在跑的时候才挂徽标；剩下的位置
/// 让给「上次导出」这种真正有用的信息。
({String label, Color color})? statusBadge(RenewTaskStatus status) =>
    switch (status) {
      RenewTaskStatus.analyzing => (label: '分析中', color: AppColors.accentBlue),
      RenewTaskStatus.ready => null,
    };

class TaskCard extends ConsumerWidget {
  /// 封面缺失/加载失败时的黑底占位（供测试定位）
  static const coverPlaceholderKey = ValueKey('task-card-cover-placeholder');

  final RenewTask task;

  /// 源视频文件是否已不存在（由 [missingSourceTaskIdsProvider] 异步探测得出，
  /// 卡片自身不碰文件系统——build 每帧都会跑）
  final bool sourceMissing;

  /// 「更多」按钮回调，参数为按钮中心的屏幕坐标（用于定位弹出菜单）
  final void Function(Offset globalPosition)? onMenu;

  const TaskCard({
    super.key,
    required this.task,
    this.sourceMissing = false,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 分析失败优先级高于普通状态徽标：只要 analysisError 非空就顶替显示
    final badge = task.analysisError != null
        ? (label: '分析失败', color: AppColors.red)
        : statusBadge(task.status);
    // 只有真正在分析的任务才看进度：分析已经结束的卡片还挂着进度条，
    // 会让人以为它又在跑了。select 保证只有本任务的进度变化才重绘本卡片。
    final progress = task.status == RenewTaskStatus.analyzing &&
            task.analysisError == null
        ? ref.watch(taskProgressOf(task.id))
        : null;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Cover(coverPath: task.coverPath),
                if (sourceMissing) const _MissingSourceOverlay(),
                // 徽标为 null = 可编辑，那是常态，不该占一块位置常驻
                if (badge != null)
                  Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      color: badge.color,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(badge.label,
                        style: const TextStyle(
                            fontSize: AppFontSize.micro,
                            fontWeight: FontWeight.w600,
                            color: Colors.black)),
                  ),
                ),
                if (progress != null)
                  Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _ProgressStrip(progress: progress)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 短编号：跟 Agent/同事沟通时的指代锚点（「把 #12 导出」），
                    // 放名字前面、弱化显示——它是句柄不是主角
                    if (task.seq != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 5),
                        child: Text('#${task.seq}',
                            style: const TextStyle(
                                fontSize: AppFontSize.body,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textTertiary,
                                fontFeatures: [FontFeature.tabularFigures()])),
                      ),
                    Expanded(
                      // 12.5 不在阶梯上（相邻两级只差 0.5px 读不出层级），
                      // 收敛到 body 级
                      child: Text(task.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: AppFontSize.body,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                    ),
                    if (onMenu != null) _MenuButton(onMenu: onMenu!),
                  ],
                ),
                // 状态徽标只说「现在是什么状态」，这一行说「接下来做什么」
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: Text(
                    taskCardHint(task, sourceMissing: sourceMissing),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.textTertiary),
                  ),
                ),
                _MetricsRow(task: task),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 这条任务的两个数：人等了多久、到现在花了多少。
///
/// 等待时间是**一次性**的（首次能进编辑那一刻就定了）；花费**一直在涨**
/// ——每次重打标都往上加。两个数放在一起，用户才看得出「这条片子值不值」。
class _MetricsRow extends StatelessWidget {
  final RenewTask task;

  const _MetricsRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final waited = formatWaited(task.firstReadyMs);
    final spent = task.aiUsage.calls == 0 ? null : formatCost(task.aiUsage);
    if (waited == null && spent == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          if (waited != null)
            _Metric(
                key: const Key('task-card-waited'),
                icon: Icons.hourglass_bottom,
                text: waited),
          if (waited != null && spent != null) const SizedBox(width: 10),
          if (spent != null)
            Tooltip(
              // 明细能对账：哪个模型调了几次、各花了多少
              message: costBreakdown(task.aiUsage).join('\n'),
              child: _Metric(
                  key: const Key('task-card-cost'),
                  icon: Icons.toll_outlined,
                  text: spent),
            ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Metric({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: AppColors.textTertiary),
          const SizedBox(width: 3),
          Text(text,
              style: const TextStyle(
                  fontSize: AppFontSize.micro,
                  color: AppColors.textTertiary)),
        ],
      );
}

/// 分析进度条：封面底部一条细进度 + 一行当前步骤。
///
/// 没有它的时候，一条 75 秒素材实测跑了十几分钟，全程只有「分析中」三个字，
/// 用户无从判断是在推进还是卡死了。
class _ProgressStrip extends StatelessWidget {
  final AnalysisProgress progress;

  const _ProgressStrip({required this.progress});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            key: const Key('task-card-progress'),
            // 无计数阶段给 null（不确定态）：一根卡在 0% 的确定态进度条，
            // 看起来就是卡死了
            value: progress.fraction,
            minHeight: 3,
            backgroundColor: AppColors.stageBackground.withValues(alpha: 0.55),
            valueColor:
                const AlwaysStoppedAnimation<Color>(AppColors.accentBlue),
          ),
          Container(
            width: double.infinity,
            color: AppColors.stageBackground.withValues(alpha: 0.72),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
            child: Text(
              '第 ${progress.stageNumber}/${AnalysisProgress.stageCount} 步 · ${progress.summary}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: AppFontSize.micro, color: AppColors.textPrimary),
            ),
          ),
        ],
      );
}

/// 源文件缺失的可见标记：压暗封面 + 左上角红色徽标 + 一句人话说明。
///
/// 只写日志或什么都不显示的后果是：封面变黑块、进审片台播放器黑屏、时间线
/// 空白，用户全程不知道发生了什么。
class _MissingSourceOverlay extends StatelessWidget {
  const _MissingSourceOverlay();

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          // 压暗封面，让上层文字有足够对比度（封面本身可能是亮画面）
          ColoredBox(
              color: AppColors.stageBackground.withValues(alpha: 0.62)),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.link_off,
                      size: AppSpacing.xl, color: AppColors.red),
                  const SizedBox(height: AppSpacing.sm),
                  Text('文件已被移动或删除',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: AppFontSize.caption,
                          height: 1.4,
                          color: AppColors.textPrimary)),
                ],
              ),
            ),
          ),
          Positioned(
            left: AppSpacing.sm,
            top: AppSpacing.sm,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm, vertical: AppSpacing.xs / 2),
              decoration: BoxDecoration(
                color: AppColors.red,
                borderRadius: BorderRadius.circular(AppRadius.xs),
              ),
              child: const Text('源文件缺失',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
            ),
          ),
        ],
      );
}

/// 任务卡封面。
///
/// 不预先探测文件是否存在：`GridView.builder` 滚动时每帧都会重建可见卡片，
/// 同步 `existsSync()` 相当于每秒对每张可见卡片做一次主线程 stat（约 12 张
/// × 60fps = 3600 次/秒），纯浪费。封面确实可能不存在（源视频被删、抽帧
/// 失败），交给 `Image.file` 的 errorBuilder 兜底即可——回落到与原来完全
/// 一致的黑底占位。
class _Cover extends StatelessWidget {
  final String? coverPath;

  const _Cover({required this.coverPath});

  @override
  Widget build(BuildContext context) {
    final path = coverPath;
    if (path == null) return const _CoverPlaceholder();
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const _CoverPlaceholder(),
    );
  }
}

/// 封面缺失/加载失败时的兜底：纯黑舞台底色，与播放器画面区一致
class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        key: TaskCard.coverPlaceholderKey,
        color: AppColors.stageBackground,
      );
}

/// 「更多」按钮：把自身中心的屏幕坐标回传，供菜单贴着按钮弹出
class _MenuButton extends StatelessWidget {
  final void Function(Offset globalPosition) onMenu;
  const _MenuButton({required this.onMenu});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: '更多',
        iconSize: 16,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        splashRadius: 14,
        color: AppColors.textSecondary,
        icon: const Icon(Icons.more_horiz),
        onPressed: () {
          final box = context.findRenderObject() as RenderBox?;
          final position = box == null
              ? Offset.zero
              : box.localToGlobal(box.size.center(Offset.zero));
          onMenu(position);
        },
      );
}
