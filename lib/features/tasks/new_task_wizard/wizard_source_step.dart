import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';

/// 第 1 步：成片来源。
///
/// 三条通道：本地文件、miaoa 成片库（未开放）、**不用原片从素材拼**。
/// miaoa 通道保留但明确标注未开放并写清原因——项目刚清理过一个「点不动、
/// 没有任何解释」的死按钮，那种控件只会让用户反复点击并怀疑软件坏了。
class WizardSourceStep extends StatelessWidget {
  final String? filePath;
  final VoidCallback onPickFile;

  /// 选了「不用原片」这一路。此时 [filePath] 一定为 null
  final bool blank;
  final VoidCallback onPickBlank;

  const WizardSourceStep({
    super.key,
    required this.filePath,
    required this.onPickFile,
    this.blank = false,
    required this.onPickBlank,
  });

  static const miaoaChannelNote = '本期未开放：需要 miaoa 成片下载通道。'
      '请先把成片下载到本地，再用「本地文件」导入。';

  @override
  Widget build(BuildContext context) {
    // 三张卡一行。多加一行会把下面的标签组区推到折叠线以下——那一区里有
    // 「重试」这类必须够得到的按钮，宁可对话框宽一点也不能让它们掉下去。
    //
    // IntrinsicHeight：三张卡等高（文案长短不一时排版才整齐）。直接用
    // CrossAxisAlignment.stretch 会在向导的滚动区（高度无界）里要求无限高。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _localCard()),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: _blankCard()),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: _miaoaCard()),
        ],
      ),
    );
  }

  Widget _localCard() {
    final picked = filePath;
    return _SourceCard(
      cardKey: const Key('wizard-pick-local-file'),
      icon: Icons.folder_open,
      title: '本地文件',
      description: picked == null
          ? '点击选择 mp4 / mov 成片'
          : '${p.basename(picked)}\n点击可重新选择',
      selected: picked != null,
      onTap: onPickFile,
    );
  }

  /// 没有参考成片、只知道要什么画面时走这条。分子手动加、标签手动填，
  /// 用标签搜出素材拼成新片
  Widget _blankCard() => _SourceCard(
        cardKey: const Key('wizard-blank-source'),
        icon: Icons.dashboard_customize_outlined,
        title: '不用原片，从素材拼',
        description: '手动加分子、打标签，用标签搜素材拼片',
        selected: blank,
        onTap: onPickBlank,
      );

  Widget _miaoaCard() => Tooltip(
        message: miaoaChannelNote,
        child: const _SourceCard(
          cardKey: Key('wizard-miaoa-source'),
          icon: Icons.link,
          title: 'miaoa 成片库',
          description: miaoaChannelNote,
          selected: false,
          onTap: null,
        ),
      );
}

class _SourceCard extends StatelessWidget {
  final Key cardKey;
  final IconData icon;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback? onTap;

  const _SourceCard({
    required this.cardKey,
    required this.icon,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return InkWell(
      key: cardKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentBlue.withValues(alpha: 0.10)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
              color: selected ? AppColors.accentBlue : AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon,
                size: 20,
                color: disabled
                    ? AppColors.textTertiary
                    : AppColors.accentBlueLight),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: disabled
                              ? AppColors.textTertiary
                              : AppColors.textPrimary,
                          fontSize: AppFontSize.body,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: AppSpacing.xs),
                  Text(description,
                      style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: AppFontSize.caption,
                          height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
