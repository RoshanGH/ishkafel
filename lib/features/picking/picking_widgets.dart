import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/replacement/replacement_plan.dart';

/// 分段控件的一段
class SegmentOption {
  final Key key;
  final String label;

  /// false 时这一段真的点不动（外层 [IgnorePointer]），而不是只画个禁用样式
  final bool enabled;

  /// 锁定态：设计稿里的「整体替换 🔒」——与单纯禁用区分，
  /// 锁定意味着"另一层已经在用了"，而不是"这功能没有"
  final bool locked;

  final VoidCallback? onTap;

  const SegmentOption({
    required this.key,
    required this.label,
    this.enabled = true,
    this.locked = false,
    this.onTap,
  });
}

/// 分段控件（互斥单选）。选中段用 [activeColor] 实心底，
/// 锁定段加删除线与锁形图标。
class PickingSegmented extends StatelessWidget {
  final List<SegmentOption> options;
  final int selectedIndex;
  final Color activeColor;

  const PickingSegmented({
    super.key,
    required this.options,
    required this.selectedIndex,
    this.activeColor = AppColors.accentBlue,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++)
            Expanded(child: _buildSegment(options[i], i == selectedIndex)),
        ],
      ),
    );
  }

  Widget _buildSegment(SegmentOption option, bool selected) {
    final color = option.locked
        ? AppColors.textTertiary
        : !option.enabled
            ? AppColors.textTertiary
            : selected
                ? AppColors.textPrimary
                : AppColors.textSecondary;
    return IgnorePointer(
      ignoring: !option.enabled,
      child: GestureDetector(
        key: option.key,
        behavior: HitTestBehavior.opaque,
        onTap: option.onTap,
        child: Container(
          // 5pt 而不是 8pt：右栏的高度全是候选区的本钱，一行分段按钮
          // 高一点就少看小半张预览图
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(
            color: selected ? activeColor : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: color,
                    fontSize: AppFontSize.caption,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    decoration:
                        option.locked ? TextDecoration.lineThrough : null,
                    decorationColor: color,
                  ),
                ),
              ),
              if (option.locked) ...[
                const SizedBox(width: AppSpacing.xs),
                const Icon(Icons.lock_outline,
                    size: 11, color: AppColors.textTertiary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 台词语义单元的替换模式 + 组合因子徽标。
///
/// 三种模式各有自己的语义色（与设计稿一致）：整体替换绿、镜头级紫、
/// 保留原片橙——用户扫一眼左栏就知道哪些单元会被替换、各贡献多少条。
class ReplacementBadge extends StatelessWidget {
  final UnitReplacement replacement;

  const ReplacementBadge({super.key, required this.replacement});

  /// 徽标文案：`整体 ×2` / `镜头级 ×6` / `保留原片`
  static String labelOf(UnitReplacement replacement) =>
      switch (replacement.mode) {
        ReplacementMode.keepOriginal => '保留原片',
        ReplacementMode.whole => '整体 ×${replacement.factor}',
        ReplacementMode.perShot => '镜头级 ×${replacement.factor}',
      };

  static Color colorOf(UnitReplacement replacement) =>
      switch (replacement.mode) {
        ReplacementMode.keepOriginal => AppColors.orange,
        ReplacementMode.whole => AppColors.green,
        ReplacementMode.perShot => AppColors.purple,
      };

  @override
  Widget build(BuildContext context) {
    final color = colorOf(replacement);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs / 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        labelOf(replacement),
        style: TextStyle(color: color, fontSize: AppFontSize.micro),
      ),
    );
  }
}

/// 面板内的提示条（空结果引导 / 失败原因 / 禁用说明）。
///
/// 一律用文字说清「发生了什么 + 下一步做什么」，不用一个孤零零的图标或空白
/// 占位——空白会被当成软件坏了。
class PickingHint extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;

  const PickingHint({
    super.key,
    required this.text,
    this.color = AppColors.textSecondary,
    this.icon = Icons.info_outline,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                  color: color, fontSize: AppFontSize.caption, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 切换替换方式会丢弃已选候选时的二次确认。
///
/// 选材是体力活——一个单元挑十来条候选是常事，点错一次就得重挑一遍，
/// 因此这一步不能静默执行。
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
