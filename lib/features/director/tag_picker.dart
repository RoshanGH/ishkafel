import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/log/app_log.dart';
import '../../core/miaoa/miaoa_tag_service.dart';

/// 选出来的一个标签：名字进行标签（行模型只存名字），id 供检索约束用。
/// id 为 null 表示词表里解析不到（极少见：组拉取失败）——只存名字不进约束
class PickedTag {
  final int? id;
  final String name;
  const PickedTag({required this.id, required this.name});
}

/// 打开标签选择器：从妙啊的标签体系（公共词表）里搜索、点选、替换。
///
/// [selected] 是当前已选的标签名（预先带勾）；[preferredGroupIds] 的组
/// 排最前（通常是任务的分子标签组——最可能用的放手边）。
/// 返回确认后的完整选择（含解析到的 id）；取消返回 null。
Future<List<PickedTag>?> showTagPicker(
  BuildContext context, {
  required MiaoaTagService tags,
  List<String> selected = const [],
  Set<int> preferredGroupIds = const {},
}) =>
    showDialog<List<PickedTag>>(
      context: context,
      builder: (_) => _TagPickerDialog(
        tags: tags,
        selected: selected,
        preferredGroupIds: preferredGroupIds,
      ),
    );

class _TagPickerDialog extends StatefulWidget {
  final MiaoaTagService tags;
  final List<String> selected;
  final Set<int> preferredGroupIds;

  const _TagPickerDialog({
    required this.tags,
    required this.selected,
    required this.preferredGroupIds,
  });

  @override
  State<_TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends State<_TagPickerDialog> {
  final TextEditingController _query = TextEditingController();
  late final Set<String> _selected = {...widget.selected};

  List<TagGroup>? _groups;
  String? _error;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final groups = await widget.tags.listGroups();
      if (!mounted) return;
      // 任务的标签组放最前，其余按词表原序
      final preferred = [
        for (final g in groups)
          if (widget.preferredGroupIds.contains(g.id)) g,
      ];
      final rest = [
        for (final g in groups)
          if (!widget.preferredGroupIds.contains(g.id) && g.tags.isNotEmpty) g,
      ];
      setState(() => _groups = [...preferred, ...rest]);
    } catch (e) {
      AppLog.warn('标签选择器拉词表失败：$e');
      if (mounted) setState(() => _error = '标签词表拉取失败，请稍后重试。');
    }
  }

  /// 确定：把选中标签解析成 id（只拉涉及的组，通常一两个）
  Future<void> _confirm() async {
    final groups = _groups ?? const <TagGroup>[];
    setState(() => _confirming = true);
    final ids = <String, int>{};
    final wanted = <int>{
      for (final g in groups)
        if (g.tags.any(_selected.contains)) g.id,
    };
    for (final groupId in wanted) {
      try {
        for (final t in await widget.tags.listTags(groupId)) {
          ids.putIfAbsent(t.name, () => t.id);
        }
      } catch (e) {
        AppLog.warn('标签选择器解析 id 失败（group=$groupId）：$e');
      }
    }
    if (!mounted) return;
    // 保持词表顺序（组序 + 组内序），词表外的已选项（历史遗留）排最后
    final ordered = <String>[
      for (final g in groups)
        for (final name in g.tags)
          if (_selected.contains(name)) name,
    ];
    final leftover = _selected.difference(ordered.toSet());
    Navigator.of(context).pop([
      for (final name in [...ordered, ...leftover])
        PickedTag(id: ids[name], name: name),
    ]);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg)),
        child: SizedBox(
          width: 560,
          height: 520,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.sm),
              child: Row(children: [
                const Text('选标签',
                    style: TextStyle(
                        fontSize: AppFontSize.title,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text('从素材库的标签体系里挑，搜得到就选得到',
                      style: const TextStyle(
                          fontSize: AppFontSize.caption,
                          color: AppColors.textTertiary)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: TextField(
                key: const ValueKey('tag-picker-search'),
                controller: _query,
                autofocus: true,
                style: const TextStyle(fontSize: AppFontSize.body),
                decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 15),
                    hintText: '搜标签或分组，例如「促单」「场景」'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(child: _body()),
            const Divider(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl, vertical: AppSpacing.sm),
              child: Row(children: [
                Text(
                    _selected.isEmpty ? '还没选标签' : '已选 ${_selected.length} 个',
                    style: const TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textTertiary)),
                const Spacer(),
                TextButton(
                    key: const ValueKey('tag-picker-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消')),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                    key: const ValueKey('tag-picker-ok'),
                    onPressed: _confirming ? null : _confirm,
                    child: Text(_confirming ? '解析中…' : '就选这些')),
              ]),
            ),
          ]),
        ),
      );

  Widget _body() {
    final error = _error;
    if (error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(error,
              style: const TextStyle(
                  fontSize: AppFontSize.body, color: AppColors.red)),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(onPressed: _load, child: const Text('重试')),
        ]),
      );
    }
    final groups = _groups;
    if (groups == null) {
      return const Center(
          child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final query = _query.text.trim();
    final visible = <(TagGroup, List<String>)>[
      for (final g in groups)
        if (query.isEmpty)
          (g, g.tags)
        else if (g.name.contains(query))
          (g, g.tags)
        else
          (g, [
            for (final t in g.tags)
              if (t.contains(query)) t,
          ]),
    ]..removeWhere((e) => e.$2.isEmpty);
    if (visible.isEmpty) {
      return const Center(
          child: Text('没有匹配的标签，换个词试试',
              style: TextStyle(
                  fontSize: AppFontSize.body, color: AppColors.textTertiary)));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl, vertical: AppSpacing.sm),
      children: [
        for (final (group, tags) in visible) ...[
          Padding(
            padding: const EdgeInsets.only(
                top: AppSpacing.sm, bottom: AppSpacing.xs),
            child: Row(children: [
              Text(group.name,
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
              if (widget.preferredGroupIds.contains(group.id)) ...[
                const SizedBox(width: AppSpacing.xs),
                const Text('本任务',
                    style: TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.accentBlueLight)),
              ],
            ]),
          ),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final name in tags)
                FilterChip(
                  label: Text(name,
                      style: const TextStyle(fontSize: AppFontSize.caption)),
                  selected: _selected.contains(name),
                  visualDensity: VisualDensity.compact,
                  onSelected: (on) => setState(
                      () => on ? _selected.add(name) : _selected.remove(name)),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
