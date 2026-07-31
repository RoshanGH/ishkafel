import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';
import '../../core/models/renew_task.dart';

/// 任务卡上下文菜单动作
enum TaskCardAction { rename, reanalyze, delete }

/// 在指定屏幕坐标弹出任务卡菜单（右键或「更多」按钮触发）
Future<TaskCardAction?> showTaskCardMenu(
    BuildContext context, Offset globalPosition) {
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
    items: const [
      PopupMenuItem(
        value: TaskCardAction.rename,
        height: 34,
        child: Text('重命名', style: _itemStyle),
      ),
      PopupMenuItem(
        value: TaskCardAction.reanalyze,
        height: 34,
        child: Text('重新分析', style: _itemStyle),
      ),
      PopupMenuDivider(height: 8),
      PopupMenuItem(
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
