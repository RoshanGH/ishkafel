import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/replacement/replacement_plan.dart';
import 'picking_controller.dart';
import 'picking_messages.dart';
import 'picking_widgets.dart';

/// 阶段②底部：单元导航条（各单元按时长占宽、带因子徽标）+ 组合数状态栏。
///
/// 状态栏必须同时回答两件事：现在能导出多少条、为什么不能导出——只显示一个
/// 数字而把「进入矩阵导出」灰掉，用户只会反复点那个按钮并怀疑软件坏了。
class PickingBottomBar extends StatelessWidget {
  final PickingController controller;
  final VoidCallback onBackToCut;

  /// 组合数超限时为 null（按钮禁用，原因显示在状态栏上）
  final VoidCallback? onEnterExport;

  const PickingBottomBar({
    super.key,
    required this.controller,
    required this.onBackToCut,
    required this.onEnterExport,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final blocked = exportBlockedReason(controller.plan);
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _UnitNavStrip(controller: controller),
              const Divider(height: 1, color: AppColors.border),
              _statusRow(blocked: blocked),
            ],
          ),
        );
      },
    );
  }

  Widget _statusRow({required String? blocked}) {
    final notice = blocked ?? (controller.plan.isEmpty ? emptyPlanNotice : null);
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  combinationSummaryText(controller.plan),
                  key: const Key('picking-combination-status'),
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: AppFontSize.body,
                      fontFeatures: [FontFeature.tabularFigures()]),
                ),
                if (notice != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    notice,
                    style: TextStyle(
                        color: blocked == null
                            ? AppColors.textSecondary
                            : AppColors.orange,
                        fontSize: AppFontSize.caption),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          OutlinedButton(
            key: const Key('picking-back-to-cut'),
            onPressed: onBackToCut,
            child: const Text('返回切分'),
          ),
          const SizedBox(width: AppSpacing.md),
          FilledButton(
            key: const Key('picking-enter-export'),
            onPressed: onEnterExport,
            child: const Text('进入矩阵导出'),
          ),
        ],
      ),
    );
  }
}

/// 单元导航条：按时长分配宽度，徽标显示各单元的组合因子。
/// 点击直接跳到该单元——十几个单元时左栏要滚，导航条是更快的横向入口。
class _UnitNavStrip extends StatelessWidget {
  final PickingController controller;

  const _UnitNavStrip({required this.controller});

  @override
  Widget build(BuildContext context) {
    if (controller.units.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 46,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: Row(
          children: [
            for (var i = 0; i < controller.units.length; i++)
              Expanded(
                // 时长越长占位越宽，与时间线上的比例一致，便于对照
                flex: controller.units[i].durationMs.clamp(1, 1 << 30),
                child: _NavBlock(controller: controller, index: i),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavBlock extends StatelessWidget {
  final PickingController controller;
  final int index;

  const _NavBlock({required this.controller, required this.index});

  @override
  Widget build(BuildContext context) {
    final replacement = controller.replacements[index];
    final color = ReplacementBadge.colorOf(replacement);
    final selected = controller.selectedUnitIndex == index;
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: GestureDetector(
        key: Key('picking-nav-$index'),
        behavior: HitTestBehavior.opaque,
        onTap: () => controller.selectUnit(index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          decoration: BoxDecoration(
            color: color.withValues(alpha: selected ? 0.30 : 0.14),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
                color: selected ? color : color.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Text(
                'U${index + 1}',
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: AppFontSize.caption,
                    fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  _factorLabel(replacement),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(color: color, fontSize: AppFontSize.micro),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 导航条上的空间很窄，只放因子本身（模式已经用颜色表达了）
  static String _factorLabel(UnitReplacement replacement) =>
      replacement.factor == 1 ? '原片' : '×${replacement.factor}';
}
