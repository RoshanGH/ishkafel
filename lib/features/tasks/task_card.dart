import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/analysis/analysis_progress.dart';
import '../../core/models/renew_task.dart';
import 'analysis_progress_store.dart';
import 'source_availability.dart';

/// 状态徽标文案与配色
({String label, Color color}) statusBadge(RenewTaskStatus status) =>
    switch (status) {
      RenewTaskStatus.analyzing => (label: '分析中', color: AppColors.accentBlue),
      RenewTaskStatus.awaitingCut => (label: '待切分确认', color: AppColors.orange),
      RenewTaskStatus.picking => (label: '选材中', color: AppColors.purple),
      RenewTaskStatus.exported => (label: '已导出', color: AppColors.green),
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
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            child: Row(
              children: [
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
          ),
        ],
      ),
    );
  }
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
