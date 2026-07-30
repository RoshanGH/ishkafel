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
  const TaskCard({super.key, required this.task});

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
            padding: const EdgeInsets.all(10),
            child: Text(task.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ),
        ],
      ),
    );
  }
}
