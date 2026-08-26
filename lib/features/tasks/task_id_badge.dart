import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/models/renew_task.dart';

/// 任务编号徽章：**进到任务里也要一眼看见自己在第几号任务上**。
///
/// 人跟 Agent（和跟人）沟通全靠这个号——「#12 的第 3 句配音不对」。看不到
/// 编号就得退出去列表页找，或者干脆报个任务名让对方去猜。所以它出现在
/// 每个模块的顶栏最左边，返回键旁边，视线第一落点。
///
/// **点一下就复制**——粘给对方是它唯一的用途，不该让人手抄。
class TaskIdBadge extends StatelessWidget {
  final RenewTask task;

  const TaskIdBadge({super.key, required this.task});

  /// 显示什么：有短号就是 `#12`。
  ///
  /// 短号是任务列表加载时补的，从 CLI 直接唤醒进来可能还没补过——那时候
  /// 显示 id 前段，总比显示一个空壳强
  String get _label =>
      task.seq != null ? '#${task.seq}' : task.id.substring(0, task.id.length.clamp(0, 8));

  /// 复制什么：**对方能直接用的东西**。`#12` 和完整 id，CLI 两个都认
  String get _payload => task.seq != null ? '#${task.seq}' : task.id;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: '任务编号 · 点击复制\n跟 Agent 说事情时报这个号',
        child: InkWell(
          key: const Key('task-id-badge'),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: _payload));
            if (!context.mounted) return;
            // 复制了要说一声，不然人不知道点没点上
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('已复制 $_payload'),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              width: 220,
            ));
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.accentBlue.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              _label,
              style: const TextStyle(
                fontSize: AppFontSize.caption,
                fontWeight: FontWeight.w600,
                color: AppColors.accentBlueLight,
                // 等宽数字：编号在不同任务间对齐，扫一眼就认得出
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      );
}
