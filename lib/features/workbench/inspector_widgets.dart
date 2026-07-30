import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';

/// InspectorPanel 的纯展示型辅助组件：不持有状态、不依赖 controller，
/// 只接收已经算好的文案/回调，从 inspector_panel.dart 中拆出以控制单文件行数。

Widget inspectorTitle(String text) => Text(
      text,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    );

Widget inspectorLabel(String text) => Text(
      text,
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
    );

Widget inspectorCard(List<Widget> children) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ]),
    );

Widget inspectorInfoRow(String label, String value) => Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        inspectorLabel(label),
        Text(value,
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()])),
      ],
    );

/// 时间码步进行：[valueText] 由调用方预先用 formatTimecode 格式化好传入，
/// 本函数不关心 fps/ms 换算逻辑。[minusEnabled]/[plusEnabled] 为 false 时
/// 按钮降低透明度且不响应点击（首/末边界无对应边界可调）。
Widget inspectorTimeRow({
  required String label,
  required String valueText,
  required Key minusKey,
  required Key plusKey,
  required bool minusEnabled,
  required bool plusEnabled,
  required VoidCallback onMinus,
  required VoidCallback onPlus,
}) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      inspectorLabel(label),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _stepButton(minusKey, '−', minusEnabled ? onMinus : null),
            const SizedBox(width: 6),
            Text(
              valueText,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 11.5,
                  fontFeatures: [FontFeature.tabularFigures()]),
            ),
            const SizedBox(width: 6),
            _stepButton(plusKey, '＋', plusEnabled ? onPlus : null),
          ],
        ),
      ),
    ],
  );
}

Widget _stepButton(Key key, String glyph, VoidCallback? onTap) {
  final enabled = onTap != null;
  return InkWell(
    key: key,
    onTap: onTap,
    borderRadius: BorderRadius.circular(4),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(glyph,
          style: TextStyle(
              color: enabled
                  ? AppColors.textTertiary
                  : AppColors.textTertiary.withValues(alpha: 0.35),
              fontSize: 13)),
    ),
  );
}

Widget inspectorTagChips(List<String> tags) {
  if (tags.isEmpty) {
    return const Text('无标签',
        style: TextStyle(color: AppColors.textTertiary, fontSize: 11));
  }
  return Wrap(
    spacing: 6,
    runSpacing: 6,
    children: tags
        .map((t) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.accentBlue.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(t,
                  style: const TextStyle(
                      color: AppColors.accentBlueLight, fontSize: 10.5)),
            ))
        .toList(growable: false),
  );
}

Widget inspectorActionsRow({
  required String mergeLabel,
  required VoidCallback onSplit,
  required VoidCallback onMerge,
}) {
  return Row(
    children: [
      Expanded(
        child: _actionButton(
          key: const Key('inspector-split-btn'),
          label: '✂ 在游标处拆分',
          onTap: onSplit,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _actionButton(
          key: const Key('inspector-merge-btn'),
          label: mergeLabel,
          onTap: onMerge,
        ),
      ),
    ],
  );
}

Widget _actionButton({
  required Key key,
  required String label,
  required VoidCallback onTap,
}) {
  return InkWell(
    key: key,
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12)),
    ),
  );
}
