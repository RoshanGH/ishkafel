import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/log/app_log.dart';
import '../../../core/miaoa/miaoa_failure.dart';
import '../../../core/miaoa/miaoa_tag_service.dart';
import '../../../core/models/tag_group_ref.dart';
import 'tag_group_field.dart';
import 'wizard_body.dart';
import 'wizard_providers.dart';

/// 弹出新建任务向导；用户取消返回 null
Future<NewTaskWizardResult?> showNewTaskWizard(BuildContext context) =>
    showDialog<NewTaskWizardResult>(
      context: context,
      builder: (_) => const NewTaskWizard(),
    );

/// 新建任务向导（模态）：① 选成片来源 ② 选两个标签组 → 开始分析
class NewTaskWizard extends ConsumerStatefulWidget {
  const NewTaskWizard({super.key});

  @override
  ConsumerState<NewTaskWizard> createState() => _NewTaskWizardState();
}

class _NewTaskWizardState extends ConsumerState<NewTaskWizard> {
  String? _filePath;
  List<TagGroup>? _groups;
  String? _groupsError;
  TagGroupRef? _unitGroup;
  TagGroupRef? _shotGroup;
  TagPreview? _unitPreview;
  TagPreview? _shotPreview;

  /// 预览请求的序号：用户快速切换标签组时，晚到的旧响应不得覆盖新选择
  int _unitPreviewToken = 0;
  int _shotPreviewToken = 0;

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

  void _selectUnitGroup(TagGroupRef group) {
    setState(() {
      _unitGroup = group;
      _unitPreview = const TagPreviewLoading();
    });
    _loadPreview(group, ++_unitPreviewToken, isUnitLayer: true);
  }

  void _selectShotGroup(TagGroupRef group) {
    setState(() {
      _shotGroup = group;
      _shotPreview = const TagPreviewLoading();
    });
    _loadPreview(group, ++_shotPreviewToken, isUnitLayer: false);
  }

  Future<void> _loadPreview(TagGroupRef group, int token,
      {required bool isUnitLayer}) async {
    TagPreview result;
    try {
      final tags = await ref.read(miaoaTagServiceProvider).listTags(group.id);
      result = TagPreviewReady(tags.map((t) => t.name).toList(growable: false));
    } catch (e) {
      AppLog.warn('读取标签组 ${group.id} 的标签失败：$e');
      result = TagPreviewFailed(miaoaFriendlyMessage(e));
    }
    if (!mounted) return;
    final stale = isUnitLayer
        ? token != _unitPreviewToken
        : token != _shotPreviewToken;
    if (stale) return;
    setState(() {
      if (isUnitLayer) {
        _unitPreview = result;
      } else {
        _shotPreview = result;
      }
    });
  }

  /// 还差哪些必填项；为空表示可以开始分析
  List<String> get _missing => [
        if (_filePath == null) '选择本地成片文件',
        if (_unitGroup == null) '选择台词语义单元标签组',
        if (_shotGroup == null) '选择视觉镜头标签组',
      ];

  void _start() {
    final path = _filePath;
    final unit = _unitGroup;
    final shot = _shotGroup;
    if (path == null || unit == null || shot == null) return;
    Navigator.of(context).pop(NewTaskWizardResult(
        filePath: path, unitTagGroup: unit, shotTagGroup: shot));
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
                    unitGroup: _unitGroup,
                    shotGroup: _shotGroup,
                    unitPreview: _unitPreview,
                    shotPreview: _shotPreview,
                    onUnitGroupChanged: _selectUnitGroup,
                    onShotGroupChanged: _selectShotGroup,
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
