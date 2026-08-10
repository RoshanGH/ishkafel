import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/miaoa/miaoa_auth_service.dart';

/// 选企业 / 选项目。两者的形状一模一样，共用一个。
///
/// **为什么必须有它**：一个账号可以属于多家企业，而**标签组是企业级的**。
/// 登录完不选企业，就落在 CLI 给的默认企业上——新建任务时根本选不到标签组，
/// 于是没有受控词表、AI 打不出标签，到了挑替换素材那一步就是「没有标签」。
/// 中间没有任何一步会报错，全程静默，用户完全无从下手（真机上就这么撞过）。
class WorkspacePickerSheet extends StatefulWidget {
  final String title;
  final String description;

  /// 拉可选项
  final Future<MiaoaWorkspaceList> Function() load;

  /// 选中之后切过去
  final Future<MiaoaAuthResult> Function(int id) select;

  /// 一个都不选也能关掉吗。登录流程里**不允许**——那正是要堵的洞
  final bool dismissible;

  const WorkspacePickerSheet({
    super.key,
    required this.title,
    required this.description,
    required this.load,
    required this.select,
    this.dismissible = true,
  });

  /// 选中并切换成功返回 true
  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required String description,
    required Future<MiaoaWorkspaceList> Function() load,
    required Future<MiaoaAuthResult> Function(int id) select,
    bool dismissible = true,
  }) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: dismissible,
        builder: (_) => Dialog(
          backgroundColor: AppColors.surfaceRaised,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
            child: WorkspacePickerSheet(
              title: title,
              description: description,
              load: load,
              select: select,
              dismissible: dismissible,
            ),
          ),
        ),
      );

  @override
  State<WorkspacePickerSheet> createState() => _WorkspacePickerSheetState();
}

class _WorkspacePickerSheetState extends State<WorkspacePickerSheet> {
  MiaoaWorkspaceList? _list;
  bool _busy = false;
  String? _error;
  int? _switching;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final list = await widget.load();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _list = list;
      _error = list.failure;
    });
  }

  Future<void> _pick(MiaoaWorkspace item) async {
    setState(() {
      _switching = item.id;
      _error = null;
    });
    final result = await widget.select(item.id);
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _switching = null;
      _error = result.message;
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                style: const TextStyle(
                    fontSize: AppFontSize.title,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            Text(widget.description,
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.5,
                    color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.md),
            Flexible(child: _body()),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!,
                  key: const Key('workspace-error'),
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      height: 1.5,
                      color: AppColors.red)),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : _reload,
                  child: const Text('重新读取'),
                ),
                if (widget.dismissible) ...[
                  const SizedBox(width: AppSpacing.sm),
                  TextButton(
                    onPressed: _switching != null
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ],
              ],
            ),
          ],
        ),
      );

  Widget _body() {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Center(
            child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    final items = _list?.items ?? const <MiaoaWorkspace>[];
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Text(
          _error != null ? '' : '这个账号下没有可选项。请联系 miaoa 管理员确认权限。',
          style: const TextStyle(
              fontSize: AppFontSize.body,
              height: 1.6,
              color: AppColors.textSecondary),
        ),
      );
    }
    return ListView.separated(
      key: const Key('workspace-list'),
      shrinkWrap: true,
      itemCount: items.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: AppColors.border),
      itemBuilder: (_, i) => _row(items[i]),
    );
  }

  Widget _row(MiaoaWorkspace item) => InkWell(
        key: Key('workspace-${item.id}'),
        onTap: _switching != null ? null : () => _pick(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.md),
          child: Row(
            children: [
              Expanded(
                child: Text(item.name,
                    style: TextStyle(
                        fontSize: AppFontSize.body,
                        color: item.current
                            ? AppColors.accentBlueLight
                            : AppColors.textPrimary)),
              ),
              if (item.current)
                const Text('当前',
                    style: TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.accentBlueLight)),
              if (_switching == item.id)
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
        ),
      );
}
