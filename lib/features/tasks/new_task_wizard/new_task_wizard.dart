import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/log/app_log.dart';
import '../../../core/miaoa/miaoa_failure.dart';
import '../../../core/miaoa/miaoa_tag_service.dart';
import '../../../core/models/project_ref.dart';
import '../../../core/models/tag_group_ref.dart';
import 'tag_group_field.dart';
import 'wizard_body.dart';
import 'wizard_providers.dart';

/// 弹出新建任务向导；用户取消返回 null。
///
/// [prefillUnitGroups]/[prefillShotGroups] 与两层的打标约束都用上一条任务的
/// 配置预填：同一个项目里连着建好几条任务是常态，每次重选四个组、重贴两段
/// 约束纯属折磨。预填只是起点，用户照样能改。
Future<NewTaskWizardResult?> showNewTaskWizard(
  BuildContext context, {
  List<TagGroupRef> prefillUnitGroups = const [],
  List<TagGroupRef> prefillShotGroups = const [],
  String prefillUnitPrompt = '',
  String prefillShotPrompt = '',
  ProjectRef? prefillProject,
}) =>
    showDialog<NewTaskWizardResult>(
      context: context,
      builder: (_) => NewTaskWizard(
        prefillUnitGroups: prefillUnitGroups,
        prefillShotGroups: prefillShotGroups,
        prefillUnitPrompt: prefillUnitPrompt,
        prefillShotPrompt: prefillShotPrompt,
        prefillProject: prefillProject,
      ),
    );

/// 新建任务向导（模态）：① 选成片来源 ② 选两个标签组 → 开始分析
class NewTaskWizard extends ConsumerStatefulWidget {
  final List<TagGroupRef> prefillUnitGroups;
  final List<TagGroupRef> prefillShotGroups;
  final String prefillUnitPrompt;
  final String prefillShotPrompt;
  final ProjectRef? prefillProject;

  const NewTaskWizard({
    super.key,
    this.prefillUnitGroups = const [],
    this.prefillShotGroups = const [],
    this.prefillUnitPrompt = '',
    this.prefillShotPrompt = '',
    this.prefillProject,
  });

  @override
  ConsumerState<NewTaskWizard> createState() => _NewTaskWizardState();
}

class _NewTaskWizardState extends ConsumerState<NewTaskWizard> {
  String? _filePath;
  List<TagGroup>? _groups;
  String? _groupsError;
  late final List<TagGroupRef> _unitGroups = [...widget.prefillUnitGroups];
  late final List<TagGroupRef> _shotGroups = [...widget.prefillShotGroups];
  late ProjectRef? _project = widget.prefillProject;
  late String _unitPrompt = widget.prefillUnitPrompt;
  late String _shotPrompt = widget.prefillShotPrompt;
  TagPreview? _unitPreview;
  TagPreview? _shotPreview;

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  /// 拉标签组列表。失败只翻译成中文引导展示，**不自动重试**——401 自动重试
  /// 只会连续撞墙，403/404 重试也不会变好，都得用户自己去处理。
  ///
  /// 前提：只在「还没有任何标签组可选」时才可能被重新调用（重试按钮只出现在
  /// 失败/空列表两种状态，此时两个下拉根本没渲染，也就不可能已有选中项）。
  /// 若将来把重试入口挪到列表已加载之后，必须同时清掉新列表里不存在的选中项，
  /// 否则 DropdownButton 会因 value 不在 items 中而断言失败。
  Future<void> _loadGroups() async {
    setState(() {
      _groups = null;
      _groupsError = null;
    });
    try {
      final groups = await ref.read(miaoaTagServiceProvider).listGroups();
      if (!mounted) return;
      setState(() => _groups = groups);
    } catch (e) {
      AppLog.warn('读取 miaoa 标签组失败：$e');
      if (!mounted) return;
      setState(() => _groupsError = miaoaFriendlyMessage(e));
    }
  }

  Future<void> _pickFile() async {
    try {
      final path = await ref.read(videoFilePickerProvider)();
      if (path == null || !mounted) return;
      setState(() => _filePath = path);
    } catch (e) {
      AppLog.warn('选择成片文件失败：$e');
      if (mounted) _showSnackBar('打开文件选择框失败，请重试。');
    }
  }

  void _showSnackBar(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  void _selectUnitGroups(List<TagGroupRef> groups) {
    setState(() {
      _unitGroups
        ..clear()
        ..addAll(groups);
      _unitPreview = _mergedPreview(groups);
    });
  }

  void _selectShotGroups(List<TagGroupRef> groups) {
    setState(() {
      _shotGroups
        ..clear()
        ..addAll(groups);
      _shotPreview = _mergedPreview(groups);
    });
  }

  /// 只改约束、不改选中的组。
  ///
  /// 与 [_selectUnitGroups] 分开：那条路每次都要重算标签预览，而约束是逐字
  /// 敲进去的——每敲一个字重算一遍预览纯属白费，预览内容也压根没变。
  /// 选中若干组后的标签预览：把它们的标签合并去重——打标用的就是这份合并
  /// 后的受控词表，预览就该长成它实际的样子。
  ///
  /// 标签随组一起拉回来（`--include-tags`），所以纯本地算，不再往返。
  TagPreview _mergedPreview(List<TagGroupRef> groups) {
    if (groups.isEmpty) return const TagPreviewReady([]);
    final merged = <String>[];
    var anyMissing = false;
    for (final g in groups) {
      final found = _groups?.where((x) => x.id == g.id).firstOrNull;
      if (found == null || found.tags.isEmpty) {
        anyMissing = true;
        continue;
      }
      for (final t in found.tags) {
        if (!merged.contains(t)) merged.add(t);
      }
    }
    // 列表没带上标签（降级路径）时不谎报「这个组没有标签」
    if (merged.isEmpty && anyMissing) return const TagPreviewLoading();
    return TagPreviewReady(merged);
  }

  /// 还差哪些必填项；为空表示可以开始分析
  List<String> get _missing => [
        if (_filePath == null) '选择本地成片文件',
        if (_unitGroups.isEmpty) '选择台词语义单元标签组',
        if (_shotGroups.isEmpty) '选择视觉镜头标签组',
      ];

  void _start() {
    final path = _filePath;
    if (path == null || _unitGroups.isEmpty || _shotGroups.isEmpty) return;
    Navigator.of(context).pop(NewTaskWizardResult(
        filePath: path,
        unitTagGroups: List.of(_unitGroups),
        shotTagGroups: List.of(_shotGroups),
        unitTagPrompt: _unitPrompt,
        shotTagPrompt: _shotPrompt,
        project: _project));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surfaceRaised,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _WizardHeader(),
              const SizedBox(height: AppSpacing.lg),
              Flexible(
                child: SingleChildScrollView(
                  child: WizardBody(
                    filePath: _filePath,
                    onPickFile: _pickFile,
                    groups: _groups,
                    groupsError: _groupsError,
                    onRetryGroups: _loadGroups,
                    unitGroups: _unitGroups,
                    shotGroups: _shotGroups,
                    unitPreview: _unitPreview,
                    shotPreview: _shotPreview,
                    onUnitGroupsChanged: _selectUnitGroups,
                    onShotGroupsChanged: _selectShotGroups,
                    unitPrompt: _unitPrompt,
                    shotPrompt: _shotPrompt,
                    // 不 setState：输入框自己管着文本，重建只会打断输入
                    onUnitPromptChanged: (v) => _unitPrompt = v,
                    onShotPromptChanged: (v) => _shotPrompt = v,
                    project: _project,
                    onProjectChanged: (p) => setState(() => _project = p),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              WizardFooter(
                missing: _missing,
                onCancel: () => Navigator.of(context).pop(),
                onStart: _start,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WizardHeader extends StatelessWidget {
  const _WizardHeader();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('新建翻新任务',
            style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: AppFontSize.title,
                fontWeight: FontWeight.w700)),
        SizedBox(height: AppSpacing.xs),
        Text('选择成片来源与两个标签组，提交后自动完成：语音转写 → 台词语义单元切分与打标 → 视觉镜头切分与打标',
            style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppFontSize.caption,
                height: 1.5)),
      ],
    );
  }
}
