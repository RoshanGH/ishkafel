import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/models/semantic_unit.dart';
import 'inspector_panel.dart' show formatTimecode;

/// 台词语义单元列表：左栏，跟随 controller 渲染可滚动列表；点击行选中该单元
/// 并把命中的 [SemanticUnit] 回抛给外部（审片台页面用来驱动播放头 seek）。
class UnitListPanel extends StatelessWidget {
  final SegmentationEditorController controller;
  final ValueChanged<SemanticUnit>? onUnitTap;

  /// 空白任务：分子是手动加出来的，所以列表头上要有「添加」。
  /// 翻新任务的分子是分析切出来的，不给这个按钮
  final VoidCallback? onAddUnit;

  /// 删掉一个分子（同样只有空白任务给）
  final ValueChanged<int>? onDeleteUnit;

  const UnitListPanel({
    super.key,
    required this.controller,
    this.onUnitTap,
    this.onAddUnit,
    this.onDeleteUnit,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final units = controller.units;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ListHeader(count: units.length, onAdd: onAddUnit),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(AppSpacing.sm),
                itemCount: units.length,
                separatorBuilder: (context, i) =>
                    const SizedBox(height: AppSpacing.xs),
                itemBuilder: (context, i) {
                  final unit = units[i];
                  final selected = controller.selection?.unitIndex == i &&
                      controller.selection?.shotIndex == null;
                  return _UnitRow(
                    unit: unit,
                    index: i,
                    fps: controller.fps,
                    selected: selected,
                    onDelete: onDeleteUnit == null
                        ? null
                        : () => onDeleteUnit!(i),
                    onTap: () {
                      controller.select(EditorSelection.unit(i));
                      onUnitTap?.call(unit);
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 列表头：标明这一栏是两层结构里的哪一层，并给出总数
class _ListHeader extends StatelessWidget {
  final int count;
  final VoidCallback? onAdd;

  const _ListHeader({required this.count, this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            '台词语义单元',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: AppFontSize.body,
              fontWeight: FontWeight.w600,
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$count 个',
                style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: AppFontSize.caption),
              ),
              if (onAdd case final add?) ...[
                const SizedBox(width: AppSpacing.sm),
                SizedBox(
                  height: 24,
                  child: FilledButton(
                    key: const Key('workbench-add-unit'),
                    onPressed: add,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('添加',
                        style: TextStyle(fontSize: AppFontSize.caption)),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _UnitRow extends StatelessWidget {
  final SemanticUnit unit;
  final int index;
  final double fps;
  final bool selected;
  final VoidCallback onTap;

  /// 空白任务才给。翻新任务的分子是分析切出来的，删掉一个等于让台词断掉
  final VoidCallback? onDelete;

  const _UnitRow({
    this.onDelete,
    required this.unit,
    required this.index,
    required this.fps,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('unit-row-$index'),
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Container(
          key: Key('unit-row-container-$index'),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accentBlue.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: selected
                ? Border.all(
                    color: AppColors.accentBlue.withValues(alpha: 0.5))
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'U${unit.index + 1}',
                    style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontWeight: FontWeight.bold,
                        fontSize: AppFontSize.caption),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    '${formatTimecode(unit.startMs, fps)}–${formatTimecode(unit.endMs, fps)}',
                    style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: AppFontSize.micro),
                  ),
                  const Spacer(),
                  // 镜头数：判断这个单元要不要展开细调的关键信息
                  _ShotCountBadge(count: unit.shots.length),
                  if (onDelete case final delete?)
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: '删掉这个分子',
                        onPressed: delete,
                        icon: const Icon(Icons.close, size: 13),
                        color: AppColors.textTertiary,
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
                    color: AppColors.textPrimary, fontSize: AppFontSize.body),
              ),
              if (unit.tags.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: unit.tags
                      .map((t) => _Chip(text: t))
                      .toList(growable: false),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 镜头数徽标：底色取中性灰，避免与标签 chip（蓝色）混淆
class _ShotCountBadge extends StatelessWidget {
  final int count;

  const _ShotCountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.textTertiary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        '$count 镜头',
        style: const TextStyle(
            color: AppColors.textSecondary, fontSize: AppFontSize.micro),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;

  const _Chip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accentBlue.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style:
              const TextStyle(color: AppColors.accentBlueLight, fontSize: AppFontSize.micro)),
    );
  }
}
