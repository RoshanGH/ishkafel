import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/script/script_doc.dart';

/// 编导台右栏：当前行的工作台。
///
/// M1 骨架：行身份 + 画面行手填时长。配音（M2）、镜头（M3）、字幕（M6）
/// 的分节会依次长在这里——「参数跟对象走」，当前行的一切深工都在此。
class LineInspector extends StatelessWidget {
  final int index;
  final ScriptLine line;
  final ValueChanged<int?> onManualMsChanged;

  const LineInspector({
    super.key,
    required this.index,
    required this.line,
    required this.onManualMsChanged,
  });

  @override
  Widget build(BuildContext context) {
    final voiced = line.type == ScriptLineType.voiced;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Row(children: [
          Text('第 ${index + 1} 行',
              style: const TextStyle(
                  fontSize: AppFontSize.emphasis,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          const SizedBox(width: AppSpacing.sm),
          _typeBadge(voiced),
        ]),
        const SizedBox(height: AppSpacing.xs),
        Text(
            voiced
                ? '配音生成后，配音时长就是这一行的时长'
                : '没有台词的行——有画面、可铺配乐',
            style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppFontSize.caption,
                height: 1.5)),
        const SizedBox(height: AppSpacing.lg),
        if (!voiced) ...[
          _sectionTitle('时长'),
          const SizedBox(height: AppSpacing.sm),
          _manualMsField(),
          const SizedBox(height: AppSpacing.xl),
        ],
        // 未来的分节按最终形态占位：让右栏此刻就有「工作台」的骨架，
        // 而不是一句孤零零的解释加一片空白
        if (voiced) ...[
          _sectionTitle('配音'),
          const SizedBox(height: AppSpacing.sm),
          _upcomingCard(Icons.graphic_eq, '选音色、生成配音、试听',
              '下个版本在这里点亮'),
          const SizedBox(height: AppSpacing.xl),
        ],
        _sectionTitle('镜头'),
        const SizedBox(height: AppSpacing.sm),
        _upcomingCard(Icons.grid_view_outlined, '找素材、排镜头位、分时长',
            '后续版本在这里点亮'),
      ],
    );
  }

  /// 尚未点亮的分节：一张低调的占位卡，说明「这里将来是什么、什么时候来」
  Widget _upcomingCard(IconData icon, String what, String when) => Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(children: [
          Icon(icon, size: 16, color: AppColors.textTertiary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(what,
                      style: const TextStyle(
                          fontSize: AppFontSize.caption,
                          color: AppColors.textSecondary)),
                  const SizedBox(height: 2),
                  Text(when,
                      style: const TextStyle(
                          fontSize: AppFontSize.micro,
                          color: AppColors.textTertiary)),
                ]),
          ),
        ]),
      );

  Widget _typeBadge(bool voiced) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: (voiced ? AppColors.accentBlue : AppColors.textTertiary)
              .withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(voiced ? '配音行' : '画面行',
            style: TextStyle(
                fontSize: AppFontSize.micro,
                fontWeight: FontWeight.w600,
                color: voiced
                    ? AppColors.accentBlueLight
                    : AppColors.textSecondary)),
      );

  Widget _sectionTitle(String text) => Text(text,
      style: const TextStyle(
          fontSize: AppFontSize.caption,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary));

  /// 画面行的手填时长：手填即根；不填则跟随所选素材（设计稿问题③）
  Widget _manualMsField() {
    final seconds =
        line.manualMs == null ? '' : (line.manualMs! / 1000).toStringAsFixed(1);
    return Row(children: [
      SizedBox(
        width: 96,
        child: TextFormField(
          key: ValueKey('manual-ms-${line.id}'),
          initialValue: seconds,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(
              fontSize: AppFontSize.body, color: AppColors.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            suffixText: '秒',
            suffixStyle: const TextStyle(
                fontSize: AppFontSize.caption, color: AppColors.textTertiary),
            hintText: '随素材',
            hintStyle: const TextStyle(
                fontSize: AppFontSize.body, color: AppColors.textTertiary),
            filled: true,
            fillColor: AppColors.surfaceRaised,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              borderSide: const BorderSide(color: AppColors.border),
            ),
          ),
          onChanged: (v) {
            final parsed = double.tryParse(v.trim());
            onManualMsChanged(parsed == null || parsed <= 0
                ? null
                : (parsed * 1000).round());
          },
        ),
      ),
      const SizedBox(width: AppSpacing.md),
      const Expanded(
        child: Text('不填则跟随所选素材的时长',
            style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: AppFontSize.caption,
                height: 1.4)),
      ),
    ]);
  }
}
