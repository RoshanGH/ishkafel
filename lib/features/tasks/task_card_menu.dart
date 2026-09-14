import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';
import '../../core/models/renew_task.dart';

/// 任务卡上下文菜单动作
enum TaskCardAction { review, rename, copy, reanalyze, delete }

/// 在指定屏幕坐标弹出任务卡菜单（右键或「更多」按钮触发）
Future<TaskCardAction?> showTaskCardMenu(
    BuildContext context, Offset globalPosition,
    {bool canReview = false,
    bool canReanalyze = true,
    bool canCopy = true}) {
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
  final overlaySize = overlay?.size ?? MediaQuery.of(context).size;
  return showMenu<TaskCardAction>(
    context: context,
    color: AppColors.surfaceCard,
    position: RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      overlaySize.width - globalPosition.dx,
      overlaySize.height - globalPosition.dy,
    ),
    items: [
      // 挑过候选才给：没有候选就没有可审的
      if (canReview) ...const [
        PopupMenuItem(
          value: TaskCardAction.review,
          height: 34,
          child: Text('审核候选', style: _itemStyle),
        ),
        PopupMenuDivider(height: 8),
      ],
      const PopupMenuItem(
        value: TaskCardAction.rename,
        height: 34,
        child: Text('重命名', style: _itemStyle),
      ),
      // 还在分析的不给复制：那时产物只有一半，抄出来的副本不能用
      if (canCopy)
        const PopupMenuItem(
          value: TaskCardAction.copy,
          height: 34,
          child: Text('复制任务', style: _itemStyle),
        ),
      // 没有原片的任务（拼片/脚本成片）无从分析，点了必失败的入口不给
      if (canReanalyze)
        const PopupMenuItem(
          value: TaskCardAction.reanalyze,
          height: 34,
          child: Text('重新分析', style: _itemStyle),
        ),
      const PopupMenuDivider(height: 8),
      const PopupMenuItem(
        value: TaskCardAction.delete,
        height: 34,
        child: Text('删除', style: _destructiveItemStyle),
      ),
    ],
  );
}

const _itemStyle =
    TextStyle(fontSize: AppFontSize.emphasis, color: AppColors.textPrimary);
const _destructiveItemStyle =
    TextStyle(fontSize: AppFontSize.emphasis, color: AppColors.red);

/// 删除二次确认（破坏性操作）；返回 true 表示用户确认删除
Future<bool> confirmDeleteTask(BuildContext context, RenewTask task) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      title: const Text('删除任务',
          style: TextStyle(fontSize: AppFontSize.title)),
      content: Text(
        '将删除「${task.name}」及其分析产物（封面、抽帧、音频缓存），原始素材文件不受影响。'
        '此操作无法撤销。',
        style: const TextStyle(fontSize: AppFontSize.emphasis, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.red),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// 复制前问一句：说清会多占多少盘，以及两条任务此后互不相干。
///
/// 不是破坏性操作，但**要占几十上百兆**——不说清楚，人点完才发现盘满了。
/// 返回 true 表示确认复制
Future<bool> confirmCopyTask(
  BuildContext context,
  RenewTask task, {
  required int bytes,
  required String newName,
}) async {
  final mb = (bytes / 1048576).toStringAsFixed(bytes > 1048576 ? 0 : 1);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      title: const Text('复制任务',
          style: TextStyle(fontSize: AppFontSize.title)),
      content: Text(
        '复制出「$newName」，切分、标签、已挑的素材、配乐、字幕、配音全都照搬。\n\n'
        '两条任务此后完全隔离：改一条不动另一条，删一条也不影响另一条。'
        '为此要把这条任务的素材、配音、人声轨一并复制一份，约占 $mb MB。',
        style: const TextStyle(fontSize: AppFontSize.emphasis, height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm-copy-task'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('复制'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// 重命名对话框；返回 null 表示取消，否则返回去除首尾空白后的新名称
Future<String?> promptRenameTask(BuildContext context, RenewTask task) =>
    showDialog<String>(
      context: context,
      builder: (dialogContext) => _RenameDialog(initialName: task.name),
    );

class _RenameDialog extends StatefulWidget {
  final String initialName;
  const _RenameDialog({required this.initialName});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('重命名任务',
            style: TextStyle(fontSize: AppFontSize.title)),
        content: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 80,
          style: const TextStyle(fontSize: AppFontSize.emphasis),
          decoration: const InputDecoration(
              counterText: '', hintText: '输入新的任务名称'),
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(onPressed: _submit, child: const Text('保存')),
        ],
      );
}
