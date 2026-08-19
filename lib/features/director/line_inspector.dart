import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/voice_catalog.dart';
import '../../core/script/script_doc.dart';

/// 编导台右栏：当前行的工作台。
///
/// M2：配音节点亮——选音色、语速、显式「生成配音」、试听、过期提示。
/// 镜头（M3）、字幕（M6）的分节会依次长在这里——「参数跟对象走」。
class LineInspector extends StatelessWidget {
  final int index;
  final ScriptLine line;
  final ValueChanged<int?> onManualMsChanged;

  /// 配音能力是否可用（语音凭据齐了才有）；不可用时按钮禁用并说明原因
  final bool voiceAvailable;

  /// 这一行正在生成配音
  final bool generating;

  /// 这一行的配音正在试听
  final bool playing;

  final VoidCallback onPickVoice;
  final ValueChanged<int> onSpeechRateChanged;
  final VoidCallback onGenerate;
  final VoidCallback onTogglePlay;

  const LineInspector({
    super.key,
    required this.index,
    required this.line,
    required this.onManualMsChanged,
    required this.voiceAvailable,
    required this.generating,
    required this.playing,
    required this.onPickVoice,
    required this.onSpeechRateChanged,
    required this.onGenerate,
    required this.onTogglePlay,
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
        if (voiced) ...[
          _voiceSection(),
          const SizedBox(height: AppSpacing.xl),
        ],
        _sectionTitle('镜头'),
        const SizedBox(height: AppSpacing.sm),
        _upcomingCard(Icons.grid_view_outlined, '找素材、排镜头位、分时长',
            '后续版本在这里点亮'),
      ],
    );
  }

  // ---- 配音节 ----

  Widget _voiceSection() {
    final vo = line.voiceover;
    final state = line.voiceState;
    final voiceName = line.voiceId == null
        ? null
        : (VoiceCatalog.byId(line.voiceId!)?.ref.name ?? line.voiceId);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle('配音'),
        const Spacer(),
        if (state == LineVoiceState.fresh)
          const _StatusChip(text: '已生成', color: AppColors.green)
        else if (state == LineVoiceState.stale)
          const _StatusChip(text: '已过期', color: AppColors.orange),
      ]),
      const SizedBox(height: AppSpacing.sm),
      // 音色
      InkWell(
        key: const ValueKey('inspector-pick-voice'),
        onTap: onPickVoice,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(children: [
            const Icon(Icons.record_voice_over_outlined,
                size: 15, color: AppColors.textSecondary),
            const SizedBox(width: AppSpacing.sm),
            Text(voiceName ?? '选择音色',
                style: TextStyle(
                    fontSize: AppFontSize.body,
                    color: voiceName == null
                        ? AppColors.textTertiary
                        : AppColors.textPrimary)),
            const Spacer(),
            const Icon(Icons.unfold_more,
                size: 14, color: AppColors.textTertiary),
          ]),
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      // 语速
      Row(children: [
        const Text('语速',
            style: TextStyle(
                fontSize: AppFontSize.caption,
                color: AppColors.textSecondary)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: _rateSelector()),
      ]),
      const SizedBox(height: AppSpacing.md),
      // 生成按钮：显式触发——改了字只标黄，点这里才花钱
      Tooltip(
        message: voiceAvailable ? '' : '尚未配置 AI 服务（语音合成），无法生成配音',
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('inspector-generate-voice'),
            onPressed: voiceAvailable && !generating ? onGenerate : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accentBlue,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              textStyle: const TextStyle(
                  fontSize: AppFontSize.body, fontWeight: FontWeight.w600),
            ),
            icon: generating
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Colors.white))
                : const Icon(Icons.graphic_eq, size: 14),
            label: Text(generating
                ? '正在生成…'
                : (vo == null ? '生成配音' : '重新生成')),
          ),
        ),
      ),
      // 试听条：旧配音也能听（过期只是提醒，不是没收）
      if (vo != null) ...[
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(children: [
            IconButton(
              key: const ValueKey('inspector-play-voice'),
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: onTogglePlay,
              icon: Icon(playing ? Icons.stop : Icons.play_arrow,
                  color: AppColors.textPrimary),
              tooltip: playing ? '停止' : '试听',
            ),
            Text('${(vo.durationMs / 1000).toStringAsFixed(1)} 秒',
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    color: AppColors.textPrimary,
                    fontFeatures: [FontFeature.tabularFigures()])),
            const Spacer(),
            if (state == LineVoiceState.stale)
              const Padding(
                padding: EdgeInsets.only(right: AppSpacing.xs),
                child: Text('内容已改，这是旧配音',
                    style: TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.orange)),
              ),
          ]),
        ),
      ],
    ]);
  }

  static const _rates = [(-25, '0.75x'), (0, '1x'), (25, '1.25x'), (50, '1.5x')];

  Widget _rateSelector() => Row(children: [
        for (final (value, label) in _rates)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: _RatePill(
              label: label,
              selected: line.speechRate == value,
              onTap: () => onSpeechRateChanged(value),
            ),
          ),
      ]);

  // ---- 通用 ----

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

class _StatusChip extends StatelessWidget {
  final String text;
  final Color color;

  const _StatusChip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: AppFontSize.micro,
                fontWeight: FontWeight.w600,
                color: color)),
      );
}

class _RatePill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RatePill(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        key: ValueKey('rate-$label'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accentBlue.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected ? AppColors.accentBlue : AppColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: AppFontSize.micro,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? AppColors.accentBlueLight
                      : AppColors.textSecondary)),
        ),
      );
}
