import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../workbench/inspector_panel.dart' show formatTimecode;
import 'picking_controller.dart';
import 'picking_widgets.dart';

/// 阶段②左栏：已锁定的台词语义单元列表。
///
/// 与阶段①的单元列表不同，这里不显示镜头数、也不可编辑切分——本阶段的关注点
/// 是「这个单元换不换、换成什么、贡献几条」，所以每行右侧是模式与因子徽标。
class PickingUnitList extends StatelessWidget {
  final PickingController controller;
  final double fps;

  const PickingUnitList({
    super.key,
    required this.controller,
    required this.fps,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.sm),
              itemCount: controller.units.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.xs),
              itemBuilder: (context, i) => _UnitRow(
                index: i,
                controller: controller,
                fps: fps,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: const Text(
        '台词语义单元 · 已锁定',
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: AppFontSize.body,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _UnitRow extends StatelessWidget {
  final int index;
  final PickingController controller;
  final double fps;

  const _UnitRow({
    required this.index,
    required this.controller,
    required this.fps,
  });

  @override
  Widget build(BuildContext context) {
    final unit = controller.units[index];
    final selected = controller.selectedUnitIndex == index;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('picking-unit-row-$index'),
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => controller.selectUnit(index),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accentBlue.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: selected
                ? Border.all(
                    color: AppColors.accentBlue.withValues(alpha: 0.5))
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'U${index + 1}',
                          style: const TextStyle(
                              color: AppColors.accentBlue,
                              fontWeight: FontWeight.bold,
                              fontSize: AppFontSize.caption),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        // 窄栏下时间码可能放不下，宁可省略也不要溢出报错
                        Flexible(
                          child: Text(
                            '${formatTimecode(unit.startMs, fps)}–'
                            '${formatTimecode(unit.endMs, fps)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.textTertiary,
                                fontSize: AppFontSize.micro),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      unit.transcript,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: AppFontSize.body),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              ReplacementBadge(replacement: controller.replacements[index]),
            ],
          ),
        ),
      ),
    );
  }
}
