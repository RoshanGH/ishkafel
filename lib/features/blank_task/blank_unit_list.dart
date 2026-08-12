import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/editing/blank_unit_ops.dart';
import '../../core/models/semantic_unit.dart';

/// 空白任务的分子列表：加、删、拖动排序、看谁填了谁没填。
///
/// 这是空白任务的**主操作区**——翻新任务的分子是分析出来的，这里的分子是
/// 一个个排出来的。所以列表要能直接反映「片子现在长什么样」：顺序就是播放
/// 顺序，填没填一眼可见。
class BlankUnitList extends StatelessWidget {
  final List<SemanticUnit> units;

  /// 每个分子已挑素材的时长；null 表示还没挑
  final int? Function(int index) durationOf;

  final int? selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;
  final ValueChanged<int> onDelete;
  final void Function(int from, int to) onReorder;

  const BlankUnitList({
    super.key,
    required this.units,
    required this.durationOf,
    required this.selectedIndex,
    required this.onSelect,
    required this.onAdd,
    required this.onDelete,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final stat = BlankUnitOps.filledStat(units, durationOf: durationOf);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(stat: stat, onAdd: onAdd),
        Expanded(
          child: units.isEmpty
              ? const _EmptyHint()
              : ReorderableListView.builder(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                  buildDefaultDragHandles: false,
                  itemCount: units.length,
                  // onReorderItem 已经替调用方修正过「插入点」下标，
                  // 不用再自己减一
                  onReorderItem: onReorder,
                  itemBuilder: (context, i) => _UnitTile(
                    key: ValueKey('blank-unit-$i'),
                    position: i,
                    unit: units[i],
                    durationMs: durationOf(i),
                    selected: selectedIndex == i,
                    onTap: () => onSelect(i),
                    onDelete: () => onDelete(i),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final BlankFillStat stat;
  final VoidCallback onAdd;

  const _Header({required this.stat, required this.onAdd});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('分子',
                      style: TextStyle(
                          fontSize: AppFontSize.body,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                ),
                FilledButton.icon(
                  key: const Key('blank-add-unit'),
                  onPressed: onAdd,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(_summary,
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textTertiary)),
          ],
        ),
      );

  /// **秒数只统计已填的分子**。没填的那些在时间线上占的是个占位长度，
  /// 把它算进总时长等于给用户一个假的数字
  String get _summary {
    if (stat.filledCount == 0 && stat.emptyCount == 0) return '还没有分子';
    final seconds = (stat.filledMs / 1000).toStringAsFixed(1);
    final filled = '已填 ${stat.filledCount} 个共 $seconds 秒';
    return stat.emptyCount == 0
        ? '$filled · 都填满了'
        : '$filled · 还有 ${stat.emptyCount} 个没填';
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Text(
          '还没有分子。\n\n点上面的「添加」加一个，给它打上标签，'
          '再用标签搜出素材填进去。几个分子按顺序接起来就是一条新片。',
          style: TextStyle(
              fontSize: AppFontSize.caption,
              height: 1.8,
              color: AppColors.textTertiary),
        ),
      );
}

class _UnitTile extends StatelessWidget {
  final int position;
  final SemanticUnit unit;
  final int? durationMs;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _UnitTile({
    super.key,
    required this.position,
    required this.unit,
    required this.durationMs,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  bool get _filled => durationMs != null && durationMs! > 0;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Material(
          color: selected ? AppColors.surfaceCard : AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: selected ? AppColors.accentBlue : AppColors.border,
                  // 没填的画虚线感的浅边框，一眼能从填好的里面挑出来
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: position,
                    child: const Padding(
                      padding: EdgeInsets.only(right: AppSpacing.sm),
                      child: Icon(Icons.drag_indicator,
                          size: 16, color: AppColors.textTertiary),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('U${position + 1}',
                            style: const TextStyle(
                                fontSize: AppFontSize.body,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary)),
                        const SizedBox(height: 2),
                        Text(
                          unit.tags.isEmpty ? '还没有标签' : unit.tags.join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: AppFontSize.caption,
                              color: unit.tags.isEmpty
                                  ? AppColors.orange
                                  : AppColors.textSecondary),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _filled
                              ? '${(durationMs! / 1000).toStringAsFixed(1)} 秒'
                              : '待填',
                          style: TextStyle(
                              fontSize: AppFontSize.caption,
                              color: _filled
                                  ? AppColors.textTertiary
                                  : AppColors.orange),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '删除这个分子',
                    onPressed: onDelete,
                    icon: const Icon(Icons.close, size: 16),
                    color: AppColors.textTertiary,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
