import 'dart:io';
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../core/models/renew_task.dart';

/// 状态徽标文案与配色
({String label, Color color}) statusBadge(RenewTaskStatus status) =>
    switch (status) {
      RenewTaskStatus.analyzing => (label: '分析中', color: AppColors.accentBlue),
      RenewTaskStatus.awaitingCut => (label: '待切分确认', color: AppColors.orange),
      RenewTaskStatus.picking => (label: '选材中', color: AppColors.purple),
      RenewTaskStatus.exported => (label: '已导出', color: AppColors.green),
    };

class TaskCard extends StatelessWidget {
  final RenewTask task;

  /// 「更多」按钮回调，参数为按钮中心的屏幕坐标（用于定位弹出菜单）
  final void Function(Offset globalPosition)? onMenu;

  const TaskCard({super.key, required this.task, this.onMenu});

  @override
  Widget build(BuildContext context) {
    // 分析失败优先级高于普通状态徽标：只要 analysisError 非空就顶替显示
    final badge = task.analysisError != null
        ? (label: '分析失败', color: AppColors.red)
        : statusBadge(task.status);
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
                if (task.coverPath != null && File(task.coverPath!).existsSync())
                  Image.file(File(task.coverPath!), fit: BoxFit.cover)
                else
                  const ColoredBox(color: Colors.black),
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
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.black)),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(task.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5,
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
