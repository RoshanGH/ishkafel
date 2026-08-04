import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/miaoa/miaoa_project_service.dart';
import '../../../core/models/project_ref.dart';

/// 「在哪个项目里找素材」。
///
/// 可填可不填：不填就是我的全部项目聚合（CLI 不传 `--projects` 的语义）。
/// 但素材库里四万多条分镜横跨几十个项目，不限项目搜出来的大多不是这条片子
/// 能用的，所以默认引导用户选一个。
class ProjectField extends ConsumerStatefulWidget {
  final ProjectRef? value;
  final ValueChanged<ProjectRef?> onChanged;

  const ProjectField({super.key, required this.value, required this.onChanged});

  @override
  ConsumerState<ProjectField> createState() => _ProjectFieldState();
}

class _ProjectFieldState extends ConsumerState<ProjectField> {
  /// 已拉回来的项目列表；null 表示还没拉过
  List<MiaoaProject>? _projects;
  bool _loading = false;
  String? _error;

  /// 点开才拉列表，而不是一挂载就拉。
  ///
  /// 多数任务沿用上一条的项目，压根不会点开这个选择器——为它每次都起一个
  /// miaoa 子进程既慢又无谓。
  Future<void> _pick() async {
    if (_loading) return;
    var projects = _projects;
    if (projects == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        projects = await ref.read(miaoaProjectServiceProvider).listProjects();
        if (!mounted) return;
        setState(() {
          _projects = projects;
          _loading = false;
        });
      } catch (e) {
        // 拉不到项目不该挡住整条流程：不选项目照样能建任务、能打标，
        // 只是检索范围变成全部项目
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = '读取项目列表失败，可先不选项目（检索范围为全部项目）';
        });
        return;
      }
    }
    if (!mounted) return;
    final picked = await showDialog<_Picked>(
      context: context,
      builder: (_) => _ProjectPickerDialog(
          projects: projects!, selectedId: widget.value?.id),
    );
    if (picked == null) return;
    widget.onChanged(picked.project);
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const Key('project-field'),
          onTap: _pick,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('项目（可不填）',
                          style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: AppFontSize.caption)),
                      const SizedBox(height: 2),
                      Text(
                        _loading
                            ? '读取项目列表…'
                            : (value?.name ?? '不限项目（我的全部项目）'),
                        style: TextStyle(
                            color: value == null
                                ? AppColors.textTertiary
                                : AppColors.textPrimary,
                            fontSize: AppFontSize.body),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_drop_down, color: AppColors.textTertiary),
              ],
            ),
          ),
        ),
        if (_error case final e?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(e,
                style: const TextStyle(
                    color: AppColors.orange, fontSize: AppFontSize.caption)),
          ),
      ],
    );
  }
}

/// 用一层包装区分「取消」（null）和「选了不限项目」（project 为 null）
class _Picked {
  final ProjectRef? project;
  const _Picked(this.project);
}

class _ProjectPickerDialog extends StatefulWidget {
  final List<MiaoaProject> projects;
  final int? selectedId;

  const _ProjectPickerDialog({required this.projects, this.selectedId});

  @override
  State<_ProjectPickerDialog> createState() => _ProjectPickerDialogState();
}

class _ProjectPickerDialogState extends State<_ProjectPickerDialog> {
  final _keyword = TextEditingController();

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  /// 本地过滤：几十个项目一次就拉全了，敲一个字起一次子进程反而卡
  List<MiaoaProject> get _hits {
    final k = _keyword.text.trim();
    if (k.isEmpty) return widget.projects;
    return [
      for (final p in widget.projects)
        if (p.name.contains(k) || '${p.id}' == k) p,
    ];
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('选择项目',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: AppFontSize.title,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  key: const Key('project-search'),
                  controller: _keyword,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: AppFontSize.body),
                  decoration: const InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.surfaceRaised,
                    border: OutlineInputBorder(),
                    hintText: '搜项目名或 ID',
                    hintStyle: TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: AppFontSize.body),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        key: const Key('project-any'),
                        dense: true,
                        title: const Text('不限项目（我的全部项目）',
                            style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: AppFontSize.body)),
                        selected: widget.selectedId == null,
                        onTap: () =>
                            Navigator.of(context).pop(const _Picked(null)),
                      ),
                      for (final p in _hits)
                        ListTile(
                          key: Key('project-${p.id}'),
                          dense: true,
                          title: Text(p.name,
                              style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: AppFontSize.body)),
                          selected: widget.selectedId == p.id,
                          onTap: () => Navigator.of(context).pop(
                              _Picked(ProjectRef(id: p.id, name: p.name))),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
