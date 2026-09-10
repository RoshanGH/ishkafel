import 'package:flutter/material.dart';

import '../shared/scroll_fade.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/voice_catalog.dart';

/// 编导台的音色选择器：单选一个音色（音色粒度 = 行，设计稿问题①）。
///
/// 保持轻：给当前行挑一个声音；整片统一音色是常态，所以多一个
/// 「同时应用到整片」勾选（[allowApplyAll]），不用一行行换 27 次。
/// 返回 (音色 id, 是否应用到整片)；取消返回 null。
Future<(String, bool)?> showVoiceSelectDialog(BuildContext context,
        {String? selected, bool allowApplyAll = false}) =>
    showDialog<(String, bool)>(
      context: context,
      builder: (_) => _VoiceSelectDialog(
          selected: selected, allowApplyAll: allowApplyAll),
    );

class _VoiceSelectDialog extends StatefulWidget {
  final String? selected;
  final bool allowApplyAll;
  const _VoiceSelectDialog({this.selected, this.allowApplyAll = false});

  @override
  State<_VoiceSelectDialog> createState() => _VoiceSelectDialogState();
}

class _VoiceSelectDialogState extends State<_VoiceSelectDialog> {
  final _keyword = TextEditingController();
  late String? _picked = widget.selected;
  bool _applyAll = false;

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = VoiceCatalog.search(_keyword.text);
    final byScene = <String, List<VoiceOption>>{};
    for (final v in options) {
      (byScene[v.scene] ??= []).add(v);
    }
    return AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      title: const Text('选择音色', style: TextStyle(fontSize: AppFontSize.title)),
      content: SizedBox(
        width: 380,
        height: 420,
        child: Column(children: [
          TextField(
            controller: _keyword,
            autofocus: true,
            style: const TextStyle(fontSize: AppFontSize.body),
            decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 15),
                hintText: '按名字或场景搜'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: options.isEmpty
                ? const Center(
                    child: Text('没有匹配的音色',
                        style: TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: AppFontSize.body)))
                : ScrollFade(
                    background: AppColors.surfaceRaised,
                    child: ListView(children: [
                    for (final entry in byScene.entries) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.sm),
                        child: Text(entry.key,
                            style: const TextStyle(
                                fontSize: AppFontSize.caption,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textTertiary)),
                      ),
                      for (final v in entry.value) _row(v),
                    ],
                  ]),
                  ),
          ),
        ]),
      ),
      actions: [
        if (widget.allowApplyAll)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: InkWell(
              key: const ValueKey('voice-apply-all'),
              onTap: () => setState(() => _applyAll = !_applyAll),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                    _applyAll
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 15,
                    color: _applyAll
                        ? AppColors.accentBlue
                        : AppColors.textTertiary),
                const SizedBox(width: 4),
                const Text('同时应用到整片',
                    style: TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textSecondary)),
              ]),
            ),
          ),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
          onPressed: _picked == null
              ? null
              : () => Navigator.of(context).pop((_picked!, _applyAll)),
          child: const Text('就用这个'),
        ),
      ],
    );
  }

  Widget _row(VoiceOption v) {
    final selected = v.ref.id == _picked;
    return InkWell(
      key: ValueKey('voice-option-${v.ref.id}'),
      onTap: () => setState(() => _picked = v.ref.id),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentBlue.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(children: [
          Icon(selected ? Icons.check_circle : Icons.circle_outlined,
              size: 15,
              color:
                  selected ? AppColors.accentBlue : AppColors.textTertiary),
          const SizedBox(width: AppSpacing.sm),
          Text(v.ref.name,
              style: const TextStyle(
                  fontSize: AppFontSize.body, color: AppColors.textPrimary)),
          const Spacer(),
          if (v.language != 'cn')
            Text(v.language,
                style: const TextStyle(
                    fontSize: AppFontSize.micro,
                    color: AppColors.textTertiary)),
        ]),
      ),
    );
  }
}
