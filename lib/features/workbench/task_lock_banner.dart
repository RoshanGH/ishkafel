import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// 「这个任务正被别人操作」的横幅。
///
/// 只把编辑禁掉而不说原因，用户只会以为软件坏了——所以这里要一次说清三件事：
/// **谁占着、现在能做什么、什么时候会好**。最后一条尤其要紧：锁会在心跳
/// 超时后自动释放，不说的话用户会以为自己被永久挡住了。
class TaskLockBanner extends StatelessWidget {
  /// 持有者标识（`agent:<pid>` / `gui:<pid>`）
  final String holder;

  /// 用户确认强制接管之后调用
  final VoidCallback onTakeover;

  const TaskLockBanner({
    super.key,
    required this.holder,
    required this.onTakeover,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        color: AppColors.orange.withValues(alpha: 0.14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.lock_clock_rounded,
                size: 16, color: AppColors.orange),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                _explain(),
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    height: 1.5,
                    color: AppColors.textPrimary),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            TextButton(
              key: const Key('lock-takeover'),
              onPressed: () => _confirm(context),
              child: const Text('强制接管'),
            ),
          ],
        ),
      );

  /// 横幅上那句话。
  ///
  /// **要区分是谁占着**：`agent:` 是真有别人在跑；`gui:` 多半是上一次没正常
  /// 退出留下的残留（进程被杀时 dispose 不会执行，锁要等心跳超时才失效）。
  /// 后一种情况下说「另一个程序正在操作」，用户会莫名其妙——明明只有他一个。
  String _explain() {
    final leftover = holder.startsWith('gui:');
    return leftover
        ? '这个任务被另一个窗口占着，或者上一次没有正常退出（$holder），当前为只读。'
            '最多一分钟后会自动解锁；等不及可以直接强制接管。'
        : '$holder 正在操作这个任务，当前为只读。'
            '它结束后会自动解锁；也可以强制接管，但那会让它后续的写入被拒绝。';
  }

  Future<void> _confirm(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('强制接管这个任务？'),
        content: Text('$holder 还在操作它。接管之后它后续的写入会被拒绝，'
            '已经写进去的改动不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('lock-takeover-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('接管', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (yes == true) onTakeover();
  }
}
