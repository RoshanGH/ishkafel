import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/replacement/picked_material.dart';
import 'picking_messages.dart';

/// 托盘里的一条：已经勾选的候选。
///
/// [material] 为 null 表示落地记录还没写好（刚勾上、首帧图还在下）——
/// 那也要占一个位置，不能凭空少一条，用户是按「我选了 3 条」来核对的。
@immutable
class PickedItem {
  final int candidateId;
  final PickedMaterial? material;

  /// 是不是这一段的预览版（播放时放的就是它）
  final bool isPreview;

  /// 这一段的目标时长，用来算时长差；为 0 表示不显示
  final int targetMs;

  const PickedItem({
    required this.candidateId,
    this.material,
    this.isPreview = false,
    this.targetMs = 0,
  });
}

/// 「已选」托盘：当前作用域勾了哪几条，一直摆在候选区最上面。
///
/// **为什么必须有**：勾选状态本来只画在候选卡上，而候选卡只有当前这一页的
/// 检索结果。换个检索方式、翻一页、甚至换个项目组之后，选过的那几条根本
/// 不在结果里，界面上一个勾都看不到——用户原话「我没有看到我选了那 3 个，
/// 我不知道是不是我那 3 个」。托盘直接按 id 把素材取回来画出来，
/// 和检索结果是什么完全无关。
class PickedTray extends StatelessWidget {
  final List<PickedItem> items;

  /// 取消勾选
  final ValueChanged<int> onRemove;

  /// 设为预览版
  final ValueChanged<int> onSetPreview;

  const PickedTray({
    super.key,
    required this.items,
    required this.onRemove,
    required this.onSetPreview,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Text(
              items.length > 1
                  ? '已选 ${items.length} 条 · ★ 的那条用于预览，导出时每条各出一版'
                  : '已选 1 条',
              style: const TextStyle(
                  color: AppColors.textTertiary, fontSize: AppFontSize.micro),
            ),
          ),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              for (final item in items) _chip(item),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(PickedItem item) => Container(
        key: Key('picked-chip-${item.candidateId}'),
        width: 260,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: AppColors.purple.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.purple.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            _thumb(item),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                _label(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: item.material == null
                      ? AppColors.textTertiary
                      : AppColors.textPrimary,
                  fontSize: AppFontSize.micro,
                ),
              ),
            ),
            _duration(item),
            _icon(
              key: Key('picked-preview-${item.candidateId}'),
              icon: item.isPreview ? Icons.star : Icons.star_border,
              color: item.isPreview ? AppColors.orange : null,
              tooltip: item.isPreview ? '预览播的就是这一条' : '设为预览版',
              onTap: () => onSetPreview(item.candidateId),
            ),
            _icon(
              key: Key('picked-remove-${item.candidateId}'),
              icon: Icons.close,
              tooltip: '取消选择',
              onTap: () => onRemove(item.candidateId),
            ),
          ],
        ),
      );

  /// 素材名/台词都没有时退回 id——总比一片空白强，用户至少能拿它去库里对
  static String _label(PickedItem item) {
    final material = item.material;
    if (material == null) return '素材 #${item.candidateId}（读取中…）';
    final label = material.label;
    return label.isEmpty ? '素材 #${item.candidateId}' : label;
  }

  /// 时长差：这一条比原坑位长了还是短了。探不出时长就不显示——
  /// 显示 0 会变成一个假徽标
  Widget _duration(PickedItem item) {
    final ms = item.material?.durationMs;
    if (ms == null || ms <= 0) return const SizedBox.shrink();
    final delta = item.targetMs <= 0
        ? null
        : durationDeltaText(candidateMs: ms, targetMs: item.targetMs);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        delta ?? candidateDurationText(ms),
        style: TextStyle(
          color: delta == null
              ? AppColors.textTertiary
              : (delta.startsWith('+') ? AppColors.orange : AppColors.green),
          fontSize: AppFontSize.micro,
        ),
      ),
    );
  }

  /// 首帧图读的是**本地文件**，不是素材库那个一天就过期的签名地址
  Widget _thumb(PickedItem item) {
    final path = item.material?.thumbPath;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        width: 18,
        height: 30,
        child: path == null || path.isEmpty
            ? Container(color: AppColors.stageBackground)
            : Image.file(File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Container(color: AppColors.stageBackground)),
      ),
    );
  }

  Widget _icon({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
  }) =>
      Tooltip(
        message: tooltip,
        child: InkWell(
          key: key,
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(icon, size: 14, color: color ?? AppColors.textSecondary),
          ),
        ),
      );
}
