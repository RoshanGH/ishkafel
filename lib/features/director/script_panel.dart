import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/script/script_doc.dart';

/// 编导台左栏：脚本。像写文档一样写——回车即新行，空行即画面行。
///
/// 这里是**总览与导航**：每行一个状态点（M1 只有草稿态），选中行
/// 右栏联动。深度操作（配音/镜头）都在右栏，这里保持轻。
class ScriptPanel extends StatelessWidget {
  final ScriptDoc doc;
  final int selected;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onInsertAfter;
  final ValueChanged<int> onRemove;
  final void Function(int from, int to) onMove;
  final void Function(int index, String text) onTextChanged;

  const ScriptPanel({
    super.key,
    required this.doc,
    required this.selected,
    required this.onSelect,
    required this.onInsertAfter,
    required this.onRemove,
    required this.onMove,
    required this.onTextChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
            child: Row(children: [
              const Text('脚本',
                  style: TextStyle(
                      fontSize: AppFontSize.body, fontWeight: FontWeight.w600)),
              const SizedBox(width: AppSpacing.sm),
              Text('${doc.lines.length} 行',
                  style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.caption)),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text('一行一句台词；空行是画面行（无台词，只有画面）',
                style: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: AppFontSize.caption)),
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: doc.lines.length,
              // onReorderItem 已经替调用方修正过「插入点」下标，直接透传
              onReorderItem: onMove,
              itemBuilder: (context, i) => _LineRow(
                key: ValueKey(doc.lines[i].id),
                index: i,
                line: doc.lines[i],
                selected: i == selected,
                deletable: doc.lines.length > 1,
                onSelect: () => onSelect(i),
                onSubmit: () => onInsertAfter(i),
                onRemove: () => onRemove(i),
                onTextChanged: (text) => onTextChanged(i, text),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LineRow extends StatefulWidget {
  final int index;
  final ScriptLine line;
  final bool selected;
  final bool deletable;
  final VoidCallback onSelect;
  final VoidCallback onSubmit;
  final VoidCallback onRemove;
  final ValueChanged<String> onTextChanged;

  const _LineRow({
    super.key,
    required this.index,
    required this.line,
    required this.selected,
    required this.deletable,
    required this.onSelect,
    required this.onSubmit,
    required this.onRemove,
    required this.onTextChanged,
  });

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.line.text);

  @override
  void didUpdateWidget(covariant _LineRow old) {
    super.didUpdateWidget(old);
    // 外部改动（排序/恢复）同步进输入框；正常输入时两者一致不动光标
    if (widget.line.text != _controller.text &&
        widget.line.id != old.line.id) {
      _controller.text = widget.line.text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visual = widget.line.type == ScriptLineType.visual;
    return Container(
      key: ValueKey('script-line-${widget.index}'),
      margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: widget.selected
            ? AppColors.accentBlue.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
            color:
                widget.selected ? AppColors.accentBlue : Colors.transparent),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 拖动把手 + 行号
          ReorderableDragStartListener(
            index: widget.index,
            child: Container(
              width: 34,
              padding: const EdgeInsets.only(top: 10),
              alignment: Alignment.topCenter,
              child: Text('${widget.index + 1}',
                  style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.caption)),
            ),
          ),
          // 状态点（M1 只有草稿灰 / 画面行空心）
          Padding(
            padding: const EdgeInsets.only(top: 13),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: visual ? Colors.transparent : AppColors.textTertiary,
                border: Border.all(color: AppColors.textTertiary),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              controller: _controller,
              maxLines: null,
              textInputAction: TextInputAction.done,
              onTap: widget.onSelect,
              onChanged: widget.onTextChanged,
              onSubmitted: (_) => widget.onSubmit(),
              style: const TextStyle(
                  fontSize: AppFontSize.body, height: 1.5),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: visual ? '画面行（无台词）' : null,
                hintStyle: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: AppFontSize.body),
                contentPadding:
                    const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              ),
            ),
          ),
          IconButton(
            key: ValueKey('script-line-remove-${widget.index}'),
            visualDensity: VisualDensity.compact,
            iconSize: 14,
            onPressed: widget.deletable ? widget.onRemove : null,
            icon: const Icon(Icons.close, color: AppColors.textTertiary),
            tooltip: '删除这一行',
          ),
        ],
      ),
    );
  }
}
