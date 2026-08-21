import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/subtitle/subtitle_style.dart';

/// 字幕样式面板（位置 / 字号 / 六色 / 遮罩）。
/// 样式粒度是**句**：全局一套基调，个别句子需要时行级覆盖。
/// [allowApplyAll] 打开时多一个「应用到整片」——调好一句觉得整片都
/// 该这样，一键提升为全局默认。返回 (样式, 是否应用到整片)
Future<(SubtitleStyle, bool)?> showSubtitleStyleSheet(BuildContext context,
        {required SubtitleStyle initial, bool allowApplyAll = false}) =>
    showDialog<(SubtitleStyle, bool)>(
      context: context,
      builder: (_) =>
          _SubtitleStyleDialog(initial: initial, allowApplyAll: allowApplyAll),
    );

/// 六色（白/黄/橙/绿/蓝/粉），hex 不带 #
const subtitleColors = <(String, String)>[
  ('FFFFFF', '白'),
  ('FFD900', '黄'),
  ('FF9F0A', '橙'),
  ('30D158', '绿'),
  ('64A8FF', '蓝'),
  ('FF6482', '粉'),
];

class _SubtitleStyleDialog extends StatefulWidget {
  final SubtitleStyle initial;
  final bool allowApplyAll;
  const _SubtitleStyleDialog(
      {required this.initial, this.allowApplyAll = false});

  @override
  State<_SubtitleStyleDialog> createState() => _SubtitleStyleDialogState();
}

class _SubtitleStyleDialogState extends State<_SubtitleStyleDialog> {
  late double _bottomRatio = widget.initial.bottomRatio;
  late double _fontRatio = widget.initial.fontRatio;
  late String _colorHex = widget.initial.colorHex ?? 'FFFFFF';
  late SubtitlePreset _mask = switch (widget.initial.preset) {
    SubtitlePreset.whiteBox => SubtitlePreset.whiteBox,
    SubtitlePreset.blurBox => SubtitlePreset.blurBox,
    _ => SubtitlePreset.whiteOutline,
  };

  SubtitleStyle get _style => SubtitleStyle(
        bottomRatio: _bottomRatio,
        fontRatio: _fontRatio,
        colorHex: _colorHex == 'FFFFFF' ? null : _colorHex,
        preset: _mask,
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      title: const Text('字幕样式', style: TextStyle(fontSize: AppFontSize.title)),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('对整条片子生效（每一行的字幕都按这套画）',
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textTertiary)),
          const SizedBox(height: AppSpacing.lg),
          _row('位置', Slider(
            key: const ValueKey('subtitle-bottom'),
            value: _bottomRatio,
            min: 0.05,
            max: 0.5,
            activeColor: AppColors.accentBlue,
            onChanged: (v) => setState(() => _bottomRatio = v),
          ), trailing: '距底 ${(_bottomRatio * 100).round()}%'),
          _row(
              '字号',
              Row(children: [
                for (final (label, v) in const [('小', 0.028), ('标准', 0.034), ('大', 0.042)])
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.xs),
                    child: ChoiceChip(
                      key: ValueKey('subtitle-font-$label'),
                      label: Text(label,
                          style: const TextStyle(fontSize: AppFontSize.caption)),
                      selected: (_fontRatio - v).abs() < 0.002,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _fontRatio = v),
                    ),
                  ),
              ])),
          _row(
              '颜色',
              Row(children: [
                for (final (hex, name) in subtitleColors)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: Tooltip(
                      message: name,
                      child: InkWell(
                        key: ValueKey('subtitle-color-$hex'),
                        onTap: () => setState(() => _colorHex = hex),
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(int.parse('FF$hex', radix: 16)),
                            border: Border.all(
                                color: _colorHex == hex
                                    ? AppColors.accentBlue
                                    : AppColors.border,
                                width: _colorHex == hex ? 2 : 1),
                          ),
                        ),
                      ),
                    ),
                  ),
              ])),
          _row(
              '遮罩',
              Row(children: [
                for (final (preset, label) in const [
                  (SubtitlePreset.whiteOutline, '无'),
                  (SubtitlePreset.blurBox, '毛玻璃'),
                  (SubtitlePreset.whiteBox, '黑底条'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.xs),
                    child: ChoiceChip(
                      key: ValueKey('subtitle-mask-${preset.name}'),
                      label: Text(label,
                          style:
                              const TextStyle(fontSize: AppFontSize.caption)),
                      selected: _mask == preset,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _mask = preset),
                    ),
                  ),
              ]),
              trailing: switch (_mask) {
                SubtitlePreset.blurBox => '字幕背后磨砂',
                SubtitlePreset.whiteBox => '半透明黑底',
                _ => '描边无底',
              }),
        ]),
      ),
      actions: [
        if (widget.allowApplyAll)
          TextButton(
            key: const ValueKey('subtitle-apply-all'),
            onPressed: () => Navigator.of(context).pop((_style, true)),
            child: const Text('应用到整片'),
          ),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
          key: const ValueKey('subtitle-confirm'),
          onPressed: () => Navigator.of(context).pop((_style, false)),
          child: const Text('就这样'),
        ),
      ],
    );
  }

  Widget _row(String label, Widget child, {String? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Row(children: [
          SizedBox(
              width: 36,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary))),
          Expanded(child: child),
          if (trailing != null)
            Text(trailing,
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textTertiary)),
        ]),
      );
}
