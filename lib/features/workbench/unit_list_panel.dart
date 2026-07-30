import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/models/semantic_unit.dart';
import 'inspector_panel.dart' show formatTimecode;

/// 台词语义单元列表：左栏，跟随 controller 渲染可滚动列表；点击行选中该单元
/// 并把命中的 [SemanticUnit] 回抛给外部（审片台页面用来驱动播放头 seek）。
class UnitListPanel extends StatelessWidget {
  final SegmentationEditorController controller;
  final ValueChanged<SemanticUnit>? onUnitTap;

  const UnitListPanel({
    super.key,
    required this.controller,
    this.onUnitTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final units = controller.units;
        return ListView.separated(
          padding: const EdgeInsets.all(10),
          itemCount: units.length,
          separatorBuilder: (context, i) => const SizedBox(height: 4),
          itemBuilder: (context, i) {
            final unit = units[i];
            final selected = controller.selection?.unitIndex == i &&
                controller.selection?.shotIndex == null;
            return _UnitRow(
              unit: unit,
              index: i,
              fps: controller.fps,
              selected: selected,
              onTap: () {
                controller.select(EditorSelection.unit(i));
                onUnitTap?.call(unit);
              },
            );
          },
        );
      },
    );
  }
}

class _UnitRow extends StatelessWidget {
  final SemanticUnit unit;
  final int index;
  final double fps;
  final bool selected;
  final VoidCallback onTap;

  const _UnitRow({
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
                        fontSize: 11),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '${formatTimecode(unit.startMs, fps)}–${formatTimecode(unit.endMs, fps)}',
                    style: const TextStyle(
                        color: AppColors.textTertiary, fontSize: 10.5),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                unit.transcript,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 12),
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
              const TextStyle(color: AppColors.accentBlueLight, fontSize: 10)),
    );
  }
}
