import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/voice_catalog.dart';
import '../../core/audio/voice_plan.dart';
import '../../core/models/semantic_unit.dart';

/// 用户在换音色面板里的决定
class VoiceChoice {
  /// 选中的音色；为 null 表示「改回原声」
  final VoiceRef? voice;

  /// 应用到哪几个台词语义单元
  final List<int> unitIndexes;

  const VoiceChoice({required this.voice, required this.unitIndexes});
}

/// 给若干台词语义单元换音色。
///
/// 面板里同时选「哪个音色」和「应用到哪几句」——用户往往是「这三句用男声、
/// 那三句用女声」，一句一句点等于把同一件事做三遍。
Future<VoiceChoice?> showVoicePicker(
  BuildContext context, {
  required List<SemanticUnit> units,
  required VoicePlan plan,

  /// 默认勾中的单元（通常是当前选中那个）
  required int focusedUnit,
}) =>
    showDialog<VoiceChoice>(
      context: context,
      builder: (_) => _VoicePickerDialog(
        units: units,
        plan: plan,
        focusedUnit: focusedUnit,
      ),
    );

class _VoicePickerDialog extends StatefulWidget {
  final List<SemanticUnit> units;
  final VoicePlan plan;
  final int focusedUnit;

  const _VoicePickerDialog({
    required this.units,
    required this.plan,
    required this.focusedUnit,
  });

  @override
  State<_VoicePickerDialog> createState() => _VoicePickerDialogState();
}

class _VoicePickerDialogState extends State<_VoicePickerDialog> {
  final _keyword = TextEditingController();
  late final Set<int> _selectedUnits = {widget.focusedUnit};
  late VoiceRef? _voice =
      widget.plan.voiceOf(widget.units[widget.focusedUnit].uid);

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = VoiceCatalog.search(_keyword.text);
    return AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      title: const Text('换音色'),
      content: SizedBox(
        width: 620,
        height: 480,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 230, child: _unitPicker()),
            const VerticalDivider(width: AppSpacing.lg, color: AppColors.border),
            Expanded(child: _voicePicker(options)),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('voice-revert'),
          onPressed: _selectedUnits.isEmpty
              ? null
              : () => Navigator.of(context).pop(VoiceChoice(
                  voice: null, unitIndexes: _selectedUnits.toList()..sort())),
          child: const Text('改回原声'),
        ),
        TextButton(
          key: const Key('voice-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('voice-confirm'),
          onPressed: _voice == null || _selectedUnits.isEmpty
              ? null
              : () => Navigator.of(context).pop(VoiceChoice(
                  voice: _voice, unitIndexes: _selectedUnits.toList()..sort())),
          child: Text(_selectedUnits.length <= 1
              ? '换这一句'
              : '换这 ${_selectedUnits.length} 句'),
        ),
      ],
    );
  }

  Widget _unitPicker() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('应用到',
                  style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppFontSize.caption)),
              const Spacer(),
              TextButton(
                key: const Key('voice-select-all'),
                onPressed: () => setState(() {
                  if (_selectedUnits.length == widget.units.length) {
                    _selectedUnits
                      ..clear()
                      ..add(widget.focusedUnit);
                  } else {
                    _selectedUnits
                      ..clear()
                      ..addAll(List.generate(widget.units.length, (i) => i));
                  }
                }),
                child: Text(
                    _selectedUnits.length == widget.units.length ? '取消全选' : '全选',
                    style: const TextStyle(fontSize: AppFontSize.caption)),
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: widget.units.length,
              itemBuilder: (_, i) {
                final unit = widget.units[i];
                final current = widget.plan.voiceOf(unit.uid);
                return CheckboxListTile(
                  key: Key('voice-unit-$i'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selectedUnits.contains(i),
                  onChanged: (on) => setState(() {
                    if (on ?? false) {
                      _selectedUnits.add(i);
                    } else {
                      _selectedUnits.remove(i);
                    }
                  }),
                  title: Text('U${i + 1}',
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: AppFontSize.caption)),
                  subtitle: Text(
                    // 已经换过的单元把音色名写出来：不写的话用户看不出
                    // 哪几句已经处理过，只能靠记
                    current == null
                        ? unit.transcript
                        : '${current.name} · ${unit.transcript}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: current == null
                            ? AppColors.textTertiary
                            : AppColors.green,
                        fontSize: AppFontSize.micro),
                  ),
                );
              },
            ),
          ),
        ],
      );

  Widget _voicePicker(List<VoiceOption> options) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('voice-search'),
            controller: _keyword,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(
                color: AppColors.textPrimary, fontSize: AppFontSize.body),
            decoration: const InputDecoration(
              isDense: true,
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(),
              hintText: '搜音色名',
              hintStyle: TextStyle(
                  color: AppColors.textTertiary, fontSize: AppFontSize.caption),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: options.isEmpty
                ? const Center(
                    child: Text('没有匹配的音色',
                        style: TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: AppFontSize.body)))
                : ListView.builder(
                    itemCount: options.length,
                    itemBuilder: (_, i) => _VoiceRow(
                      option: options[i],
                      selected: _voice?.id == options[i].ref.id,
                      onTap: () => setState(() => _voice = options[i].ref),
                    ),
                  ),
          ),
        ],
      );
}

class _VoiceRow extends StatelessWidget {
  final VoiceOption option;
  final bool selected;
  final VoidCallback onTap;

  const _VoiceRow(
      {required this.option, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        key: Key('voice-option-${option.ref.id}'),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accentBlue.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(option.ref.name,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: AppFontSize.body)),
                    Text(
                        '${option.scene}'
                        '${option.language == 'cn' ? '' : ' · ${option.language}'}',
                        style: const TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: AppFontSize.micro)),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check, size: 16, color: AppColors.accentBlue),
            ],
          ),
        ),
      );
}
