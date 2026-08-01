import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/miaoa/miaoa_tag_service.dart';
import '../../../core/models/tag_group_ref.dart';
import 'tag_group_search.dart';

/// 标签组选择弹层：搜索框 + 实时过滤的列表。
///
/// 为什么不用下拉菜单：真实租户里有 127 个标签组、2461 个标签，在一个长列表
/// 里一个个翻是当前最费劲的一步。搜索同时匹配组名与**组内标签名**——用户
/// 往往记得住某个标签叫什么、却记不住它归在哪个组。
///
/// 过滤全在本地：标签组连同标签一次拉回来才 210KB，本地过滤才是真正的
/// 「敲一个字就出结果」；走服务端每敲一个字起一次子进程还得防抖，反而卡。
Future<TagGroupRef?> showTagGroupPicker(
  BuildContext context, {
  required String title,
  required List<TagGroup> groups,
  TagGroupRef? selected,
}) =>
    showDialog<TagGroupRef>(
      context: context,
      builder: (_) =>
          _PickerDialog(title: title, groups: groups, selected: selected),
    );

class _PickerDialog extends StatefulWidget {
  final String title;
  final List<TagGroup> groups;
  final TagGroupRef? selected;

  const _PickerDialog(
      {required this.title, required this.groups, this.selected});

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  late final TextEditingController _controller = TextEditingController();
  String _keyword = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hits = searchTagGroups(widget.groups, _keyword);
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg,
                  AppSpacing.lg, AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title,
                      style: const TextStyle(
                          fontSize: AppFontSize.emphasis,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    key: const Key('tag-group-search'),
                    controller: _controller,
                    autofocus: true,
                    onChanged: (v) => setState(() => _keyword = v),
                    style: const TextStyle(
                        fontSize: AppFontSize.body,
                        color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索组名或标签名',
                      hintStyle: const TextStyle(
                          fontSize: AppFontSize.body,
                          color: AppColors.textTertiary),
                      prefixIcon: const Icon(Icons.search,
                          size: 15, color: AppColors.textTertiary),
                      prefixIconConstraints:
                          const BoxConstraints(minWidth: 30, minHeight: 30),
                      filled: true,
                      fillColor: AppColors.background,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text('共 ${widget.groups.length} 个标签组，当前匹配 ${hits.length} 个',
                      style: const TextStyle(
                          fontSize: AppFontSize.micro,
                          color: AppColors.textTertiary)),
                ],
              ),
            ),
            Flexible(
              child: hits.isEmpty
                  ? const _NoMatch()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                      itemCount: hits.length,
                      itemBuilder: (_, i) => _HitTile(
                        hit: hits[i],
                        isSelected: widget.selected?.id == hits[i].group.id,
                        onTap: () => Navigator.of(context).pop(TagGroupRef(
                            id: hits[i].group.id, name: hits[i].group.name)),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoMatch extends StatelessWidget {
  const _NoMatch();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Text('没有匹配的标签组。可以试试标签名——比如「特写」「口播」。',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: AppFontSize.body, color: AppColors.textSecondary)),
      );
}

class _HitTile extends StatelessWidget {
  final TagGroupHit hit;
  final bool isSelected;
  final VoidCallback onTap;

  const _HitTile(
      {required this.hit, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final group = hit.group;
    return Material(
      color: isSelected
          ? AppColors.accentBlue.withValues(alpha: 0.14)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(group.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: AppFontSize.body,
                            color: AppColors.textPrimary)),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  // 真实租户里存在同名不同类型的组（「脚本话术」同时有 AUDIO
                  // 与 STORYBOARD 两个），只显示名字用户无从分辨
                  Text(group.materialType,
                      style: const TextStyle(
                          fontSize: AppFontSize.micro,
                          color: AppColors.textTertiary)),
                  const Spacer(),
                  Text('${group.tags.length} 个标签',
                      style: const TextStyle(
                          fontSize: AppFontSize.micro,
                          color: AppColors.textTertiary)),
                ],
              ),
              if (hit.matchedTags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text('含标签：${hit.matchedTags.take(4).join('、')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: AppFontSize.micro,
                          color: AppColors.accentBlueLight)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
