import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/miaoa/miaoa_tag_service.dart';
import '../../../core/models/tag_group_ref.dart';
import 'tag_group_picker.dart';

/// 组内标签预览的三态（选中标签组后展开显示，让用户确认选对了组）
sealed class TagPreview {
  const TagPreview();
}

class TagPreviewLoading extends TagPreview {
  const TagPreviewLoading();
}

class TagPreviewReady extends TagPreview {
  final List<String> tags;
  const TagPreviewReady(this.tags);
}

class TagPreviewFailed extends TagPreview {
  /// 已翻译成人话的中文说明
  final String message;
  const TagPreviewFailed(this.message);
}

/// 预览最多显示的标签数，其余折成「+N」——一个组可能有几十个标签，
/// 全铺出来会把向导撑得很长，而用户只需要「看一眼确认没选错组」
const _previewLimit = 6;

/// 一个标签组选择器：标题 + 下拉 + 组内标签预览
class TagGroupField extends StatelessWidget {
  final Key dropdownKey;
  final String label;
  final String hint;
  final List<TagGroup> groups;
  final TagGroupRef? selected;
  final ValueChanged<TagGroupRef> onChanged;
  final TagPreview? preview;

  const TagGroupField({
    super.key,
    required this.dropdownKey,
    required this.label,
    required this.hint,
    required this.groups,
    required this.selected,
    required this.onChanged,
    required this.preview,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: AppFontSize.caption)),
          const SizedBox(height: AppSpacing.sm),
          _trigger(context),
          if (preview != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _PreviewArea(preview: preview!),
          ],
        ],
      ),
    );
  }

  /// 点开一个带搜索的选择弹层，而不是铺一个 127 项的下拉——
  /// 在长列表里一个个翻是新建任务里最费劲的一步
  Widget _trigger(BuildContext context) {
    final current = selected;
    final group = current == null
        ? null
        : groups.where((g) => g.id == current.id).firstOrNull;
    return InkWell(
      key: dropdownKey,
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () async {
        final picked = await showTagGroupPicker(context,
            title: label, groups: groups, selected: selected);
        if (picked != null) onChanged(picked);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: current == null
                  ? Text(hint,
                      style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: AppFontSize.body))
                  : _GroupItem(
                      group: group ??
                          TagGroup(
                              id: current.id,
                              name: current.name,
                              materialType: '',
                              tagType: '')),
            ),
            const Icon(Icons.arrow_drop_down,
                size: 18, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// 下拉项：组名 + 素材类型徽标。
///
/// 必须带素材类型：真实租户里存在同名不同类型的组（如「脚本话术」同时存在
/// AUDIO 与 STORYBOARD 两个），只显示名字用户无从分辨。
class _GroupItem extends StatelessWidget {
  final TagGroup group;
  const _GroupItem({required this.group});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(group.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: AppFontSize.body)),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(group.materialType,
            style: const TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.micro)),
      ],
    );
  }
}

class _PreviewArea extends StatelessWidget {
  final TagPreview preview;
  const _PreviewArea({required this.preview});

  @override
  Widget build(BuildContext context) => switch (preview) {
        TagPreviewLoading() => const Text('正在读取组内标签…',
            style: TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.caption)),
        TagPreviewFailed(:final message) => Text(message,
            style: const TextStyle(
                color: AppColors.orange, fontSize: AppFontSize.caption)),
        TagPreviewReady(:final tags) => _chips(tags),
      };

  Widget _chips(List<String> tags) {
    if (tags.isEmpty) {
      return const Text('这个标签组里还没有标签，选它等于不打标',
          style: TextStyle(
              color: AppColors.orange, fontSize: AppFontSize.caption));
    }
    final shown = tags.take(_previewLimit).toList(growable: false);
    final rest = tags.length - shown.length;
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final tag in shown) _MiniChip(text: tag),
        if (rest > 0) _MiniChip(text: '+$rest'),
      ],
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String text;
  const _MiniChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.accentBlue.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(text,
          style: const TextStyle(
              color: AppColors.accentBlueLight, fontSize: AppFontSize.micro)),
    );
  }
}
