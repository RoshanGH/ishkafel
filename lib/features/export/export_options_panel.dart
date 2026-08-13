import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/export/export_spec.dart';

/// 导出前要定的两件事：**出多少条**、**出多大多清楚**。
///
/// 单独一个组件，因为导出确认页本来就长（进度、历史、失败原因都在那儿），
/// 再塞两组选项进去就没法看了。
class ExportOptionsPanel extends StatelessWidget {
  final ExportSpec spec;
  final ValueChanged<ExportSpec> onSpecChanged;

  /// 全部排列组合有多少条
  final int totalCombos;

  /// null = 全部导出；否则是「只挑这么多条差异最大的」
  final int? pickCount;
  final ValueChanged<int?> onPickCountChanged;

  final bool enabled;

  const ExportOptionsPanel({
    super.key,
    required this.spec,
    required this.onSpecChanged,
    required this.totalCombos,
    required this.pickCount,
    required this.onPickCountChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('导出哪几条'),
          const SizedBox(height: AppSpacing.xs),
          _pickMode(),
          const SizedBox(height: AppSpacing.md),
          _label('画面规格'),
          const SizedBox(height: AppSpacing.xs),
          Row(children: [
            Expanded(child: _resolution()),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: _quality()),
          ]),
          const SizedBox(height: AppSpacing.xs),
          const Text('帧率固定 30fps（竖屏投放的既定标准）',
              style: TextStyle(
                  fontSize: AppFontSize.micro, color: AppColors.textTertiary)),
        ],
      );

  Widget _label(String text) => Text(text,
      style: const TextStyle(
          fontSize: AppFontSize.caption,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary));

  Widget _pickMode() {
    // 组合只有一条时没得挑，别摆一个选了也没用的开关
    if (totalCombos <= 1) {
      return const Text('只有 1 条组合',
          style: TextStyle(
              fontSize: AppFontSize.caption, color: AppColors.textTertiary));
    }
    final picking = pickCount != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _choice(
            key: const Key('export-mode-all'),
            label: '全部 $totalCombos 条',
            selected: !picking,
            onTap: () => onPickCountChanged(null),
          ),
          const SizedBox(width: AppSpacing.sm),
          _choice(
            key: const Key('export-mode-pick'),
            label: '挑差异最大的',
            selected: picking,
            // 默认挑 5 条，或者全部（组合少于 5 条时）
            onTap: () => onPickCountChanged(totalCombos < 5 ? totalCombos : 5),
          ),
        ]),
        if (picking) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(children: [
            const Text('挑 ',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
            for (final n in _pickOptions) ...[
              _choice(
                key: Key('export-pick-$n'),
                label: '$n',
                selected: pickCount == n,
                onTap: () => onPickCountChanged(n),
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
            const Text(' 条',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            '按素材本身的差异挑：同一批拍摄出来的素材算「一样」，'
            '并尽量让每条素材都露一次面',
            style: TextStyle(
                fontSize: AppFontSize.micro,
                height: 1.5,
                color: AppColors.textTertiary),
          ),
        ],
      ],
    );
  }

  List<int> get _pickOptions =>
      [for (final n in const [3, 5, 10, 20]) if (n < totalCombos) n];

  Widget _resolution() => _dropdown<String>(
        value: spec.resolutionLabel,
        items: [
          for (final r in ExportSpec.resolutions)
            ('${r.width}×${r.height}', r.label),
        ],
        onChanged: (value) {
          final r = ExportSpec.resolutions
              .firstWhere((r) => '${r.width}×${r.height}' == value);
          onSpecChanged(spec.copyWith(width: r.width, height: r.height));
        },
      );

  Widget _quality() => _dropdown<String>(
        value: spec.qualityLabel,
        items: [for (final q in ExportSpec.qualities) (q.label, q.label)],
        onChanged: (value) {
          final q = ExportSpec.qualities.firstWhere((q) => q.label == value);
          onSpecChanged(spec.copyWith(crf: q.crf));
        },
      );

  Widget _dropdown<T>({
    required String value,
    required List<(String, String)> items,
    required ValueChanged<String> onChanged,
  }) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        isDense: true,
        dropdownColor: AppColors.surfaceCard,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          border: OutlineInputBorder(),
        ),
        style: const TextStyle(
            fontSize: AppFontSize.caption, color: AppColors.textPrimary),
        items: [
          for (final (key, label) in items)
            DropdownMenuItem(value: key, child: Text(label)),
        ],
        onChanged:
            enabled ? (value) => value == null ? null : onChanged(value) : null,
      );

  Widget _choice({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      InkWell(
        key: key,
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentBlue : AppColors.surfaceCard,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  color: selected ? Colors.white : AppColors.textSecondary)),
        ),
      );
}
