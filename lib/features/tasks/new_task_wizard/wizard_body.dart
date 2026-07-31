import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/miaoa/miaoa_tag_service.dart';
import '../../../core/models/tag_group_ref.dart';
import 'tag_group_field.dart';
import 'wizard_source_step.dart';

/// 向导正文（两步），纯展示：状态与回调由 [NewTaskWizard] 持有
class WizardBody extends StatelessWidget {
  final String? filePath;
  final VoidCallback onPickFile;

  /// null 表示标签组仍在读取中
  final List<TagGroup>? groups;

  /// 非 null 表示读取失败，内容已是面向用户的中文引导
  final String? groupsError;
  final VoidCallback onRetryGroups;

  final TagGroupRef? unitGroup;
  final TagGroupRef? shotGroup;
  final TagPreview? unitPreview;
  final TagPreview? shotPreview;
  final ValueChanged<TagGroupRef> onUnitGroupChanged;
  final ValueChanged<TagGroupRef> onShotGroupChanged;

  const WizardBody({
    super.key,
    required this.filePath,
    required this.onPickFile,
    required this.groups,
    required this.groupsError,
    required this.onRetryGroups,
    required this.unitGroup,
    required this.shotGroup,
    required this.unitPreview,
    required this.shotPreview,
    required this.onUnitGroupChanged,
    required this.onShotGroupChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _StepLabel('第 1 步 · 成片来源'),
        WizardSourceStep(filePath: filePath, onPickFile: onPickFile),
        const SizedBox(height: AppSpacing.lg),
        const _StepLabel('第 2 步 · 标签组（打标的受控词表，来自 miaoa）'),
        _tagGroupSection(),
      ],
    );
  }

  Widget _tagGroupSection() {
    final error = groupsError;
    if (error != null) {
      return _NoticeBox(message: error, onRetry: onRetryGroups);
    }
    final list = groups;
    if (list == null) return const _LoadingBox();
    if (list.isEmpty) {
      return _NoticeBox(
        message: 'miaoa 里没有可用的标签组。没有标签组就无法打标，'
            '后续也检索不到候选素材。请先在 miaoa 后台建好标签组并添加标签，再回来新建任务。',
        onRetry: onRetryGroups,
      );
    }
    return Column(
      children: [
        TagGroupField(
          dropdownKey: const Key('wizard-unit-tag-group'),
          label: '台词语义单元标签组',
          hint: '选择用于台词打标的标签组',
          groups: list,
          selected: unitGroup,
          onChanged: onUnitGroupChanged,
          preview: unitPreview,
        ),
        const SizedBox(height: AppSpacing.md),
        TagGroupField(
          dropdownKey: const Key('wizard-shot-tag-group'),
          label: '视觉镜头标签组',
          hint: '选择用于画面打标的标签组',
          groups: list,
          selected: shotGroup,
          onChanged: onShotGroupChanged,
          preview: shotPreview,
        ),
      ],
    );
  }
}

class _StepLabel extends StatelessWidget {
  final String text;
  const _StepLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(text,
            style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppFontSize.caption,
                fontWeight: FontWeight.w600)),
      );
}

class _LoadingBox extends StatelessWidget {
  const _LoadingBox();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Row(
          children: [
            SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: AppSpacing.sm),
            Text('正在从 miaoa 读取标签组…',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppFontSize.caption)),
          ],
        ),
      );
}

/// 失败/空列表提示：一句人话 + 一个可执行动作
class _NoticeBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _NoticeBox({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message,
              style: const TextStyle(
                  color: AppColors.orange,
                  fontSize: AppFontSize.caption,
                  height: 1.5)),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 底部：耗时预期 + 禁用理由 + 取消/开始
class WizardFooter extends StatelessWidget {
  /// 还差哪些必填项；为空表示可以开始
  final List<String> missing;
  final VoidCallback onCancel;
  final VoidCallback onStart;

  const WizardFooter({
    super.key,
    required this.missing,
    required this.onCancel,
    required this.onStart,
  });

  static const durationNote = '预计分析耗时 1~2 分钟（96 秒素材实测）· 消耗云端 API 额度\n'
      '分析完成后进入「切分确认」';

  @override
  Widget build(BuildContext context) {
    final ready = missing.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!ready) _blockedReason(),
        Row(
          children: [
            const Expanded(
              child: Text(durationNote,
                  style: TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.micro,
                      height: 1.5)),
            ),
            TextButton(onPressed: onCancel, child: const Text('取消')),
            const SizedBox(width: AppSpacing.sm),
            FilledButton(
              key: const Key('wizard-start-btn'),
              onPressed: ready ? onStart : null,
              child: const Text('开始分析'),
            ),
          ],
        ),
      ],
    );
  }

  /// 禁用按钮必须说清「还差什么」与「不选的后果」，否则用户只会反复点它
  Widget _blockedReason() => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(
          '还需要：${missing.join('、')}。'
          '标签是后续「按相同标签检索候选素材」的唯一依据，不选就没有候选素材可用。',
          style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: AppFontSize.caption,
              height: 1.5),
        ),
      );
}
