import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/project_ref.dart';
import '../../core/models/tag_group_ref.dart';
import '../tasks/new_task_wizard/project_field.dart';
import '../tasks/new_task_wizard/tag_group_picker.dart';
import '../tasks/new_task_wizard/tag_prompt_field.dart';
import '../tasks/new_task_wizard/wizard_providers.dart';

/// 用户在这个对话框里定下来的两层标签组
class TaskTagGroups {
  final List<TagGroupRef> unit;
  final List<TagGroupRef> shot;

  /// 两层各自的打标约束（一层一条，不随组数变化）
  final String unitPrompt;
  final String shotPrompt;

  /// 在哪个项目里找素材；null 表示不限项目
  final ProjectRef? project;

  /// 确认时是否要求立刻重新打标
  final bool retagNow;

  const TaskTagGroups({
    required this.unit,
    required this.shot,
    this.unitPrompt = '',
    this.shotPrompt = '',
    this.project,
    required this.retagNow,
  });
}

/// 改这条任务用哪些标签组。
///
/// 为什么这个入口必须存在：标签组本来只在新建向导里选一次，选漏了或选错了
/// 就再也改不了——那条任务从此打不出标签，候选检索也就永远用不了标签这条
/// 主路径。而「当初选了什么」在做的过程中才看得出对不对。
Future<TaskTagGroups?> showTaskTagGroupsDialog(
  BuildContext context, {
  required List<TagGroupRef> unit,
  required List<TagGroupRef> shot,
  String unitPrompt = '',
  String shotPrompt = '',
  ProjectRef? project,
}) =>
    showDialog<TaskTagGroups>(
      context: context,
      builder: (_) => _Dialog(
          unit: unit,
          shot: shot,
          unitPrompt: unitPrompt,
          shotPrompt: shotPrompt,
          project: project),
    );

class _Dialog extends ConsumerStatefulWidget {
  final List<TagGroupRef> unit;
  final List<TagGroupRef> shot;
  final String unitPrompt;
  final String shotPrompt;
  final ProjectRef? project;
  const _Dialog({
    required this.unit,
    required this.shot,
    required this.unitPrompt,
    required this.shotPrompt,
    required this.project,
  });

  @override
  ConsumerState<_Dialog> createState() => _DialogState();
}

class _DialogState extends ConsumerState<_Dialog> {
  late List<TagGroupRef> _unit = widget.unit;
  late List<TagGroupRef> _shot = widget.shot;
  late ProjectRef? _project = widget.project;
  late String _unitPrompt = widget.unitPrompt;
  late String _shotPrompt = widget.shotPrompt;
  bool _retag = true;

  /// 标签组列表：拉取中为 null，失败时 [_loadError] 有值
  List<TagGroup>? _groups;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final groups = await ref.read(miaoaTagServiceProvider).listGroups();
      if (mounted) setState(() => _groups = groups);
    } catch (e) {
      // 不把原始异常摊给用户：他既看不懂也做不了什么
      if (mounted) {
        setState(() => _loadError = '读取标签组失败，请确认已登录 miaoa 后重试');
      }
    }
  }

  Future<void> _pick({required bool unitLayer}) async {
    final groups = _groups;
    if (groups == null) return;
    final picked = await showTagGroupPicker(
      context,
      title: unitLayer ? '选择台词语义单元标签组' : '选择视觉镜头标签组',
      groups: groups,
      selected: unitLayer ? _unit : _shot,
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (unitLayer) {
        _unit = picked;
      } else {
        _shot = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('标签组设置'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_loadError case final e?)
                Text(e,
                    style: const TextStyle(
                        color: AppColors.red, fontSize: AppFontSize.body))
              else ...[
                // 项目在最上面：先定「上哪儿找」，再定「按什么找」
                ProjectField(
                  value: _project,
                  onChanged: (p) => setState(() => _project = p),
                ),
                const SizedBox(height: AppSpacing.sm),
                _row(
                  key: const Key('task-tag-groups-unit'),
                  label: '台词语义单元标签组',
                  selected: _unit,
                  onTap: () => _pick(unitLayer: true),
                ),
                if (_unit.isNotEmpty)
                  TagPromptField(
                    layer: 'unit',
                  layerLabel: '台词语义单元',
                  value: _unitPrompt,
                  onChanged: (v) => _unitPrompt = v,
                ),
                const SizedBox(height: AppSpacing.sm),
                _row(
                  key: const Key('task-tag-groups-shot'),
                  label: '视觉镜头标签组',
                  selected: _shot,
                  onTap: () => _pick(unitLayer: false),
                ),
                if (_shot.isNotEmpty)
                  TagPromptField(
                    layer: 'shot',
                  layerLabel: '视觉镜头',
                  value: _shotPrompt,
                  onChanged: (v) => _shotPrompt = v,
                ),
                const SizedBox(height: AppSpacing.md),
                CheckboxListTile(
                  key: const Key('task-tag-groups-retag'),
                  value: _retag,
                  onChanged: (v) => setState(() => _retag = v ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('保存后立即用新词表重新打标',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: AppFontSize.body)),
                  subtitle: const Text('换了词表而不重打，标签还是按旧词表打的',
                      style: TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: AppFontSize.caption)),
                ),
              ],
            ],
          ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('task-tag-groups-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('task-tag-groups-save'),
            onPressed: _groups == null
                ? null
                : () => Navigator.of(context).pop(TaskTagGroups(
                      unit: _unit,
                      shot: _shot,
                      unitPrompt: _unitPrompt,
                      shotPrompt: _shotPrompt,
                      project: _project,
                      retagNow: _retag,
                    )),
            child: const Text('保存'),
          ),
        ],
      );

  Widget _row({
    required Key key,
    required String label,
    required List<TagGroupRef> selected,
    required VoidCallback onTap,
  }) =>
      InkWell(
        key: key,
        onTap: _groups == null ? null : onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppFontSize.caption)),
              const SizedBox(height: 2),
              Text(
                _groups == null && _loadError == null
                    ? '正在读取标签组…'
                    : selected.isEmpty
                        // 这行是「现在是什么状态」，不是一个开关。写「不打标」
                        // 会被读成设置项，用户以为得去别处才能打开
                        ? '未选择，因此这一层不会打标；选一个组就会打'
                        : selected.map((g) => g.name).join('、'),
                style: TextStyle(
                    color: selected.isEmpty
                        ? AppColors.textTertiary
                        : AppColors.textPrimary,
                    fontSize: AppFontSize.body),
              ),
            ],
          ),
        ),
      );
}
