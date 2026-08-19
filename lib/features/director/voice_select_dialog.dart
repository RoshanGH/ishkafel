import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/voice_catalog.dart';

/// 编导台的音色选择器：单选一个音色（音色粒度 = 行，设计稿问题①）。
///
/// 与工作台的换音色面板不同：那边要同时勾选「应用到哪几句」，
/// 这边就是给当前行挑一个声音，保持轻。
Future<String?> showVoiceSelectDialog(BuildContext context,
        {String? selected}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _VoiceSelectDialog(selected: selected),
    );

class _VoiceSelectDialog extends StatefulWidget {
  final String? selected;
  const _VoiceSelectDialog({this.selected});

  @override
  State<_VoiceSelectDialog> createState() => _VoiceSelectDialogState();
}

class _VoiceSelectDialogState extends State<_VoiceSelectDialog> {
  final _keyword = TextEditingController();
  late String? _picked = widget.selected;

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
                : ListView(children: [
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
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
          onPressed:
              _picked == null ? null : () => Navigator.of(context).pop(_picked),
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
