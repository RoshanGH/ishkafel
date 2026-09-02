import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/ui/text_editing_keys.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/script/script_doc.dart';

/// 编导台左栏：脚本。像写文档一样写——回车即新行，空行即画面行。
///
/// 这里是**总览与导航**：选中行右栏联动；深度操作（配音/镜头）都在右栏，
/// 这里保持轻。行卡的克制原则：常态只有行号、状态点、文字；拖柄和删除
/// 都藏在 hover 里——写作界面上常驻的每一个控件都在跟文字抢注意力。
class ScriptPanel extends StatelessWidget {
  final ScriptDoc doc;
  final int selected;

  /// 刚插入的行 id：它的输入框要自动聚焦（回车后手不离键盘继续写）
  final String? autofocusLineId;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onInsertAfter;
  final ValueChanged<int> onRemove;
  final void Function(int from, int to) onMove;
  final void Function(int index, String text) onTextChanged;

  const ScriptPanel({
    super.key,
    required this.doc,
    required this.selected,
    this.autofocusLineId,
    required this.onSelect,
    required this.onInsertAfter,
    required this.onRemove,
    required this.onMove,
    required this.onTextChanged,
  });

  @override
  Widget build(BuildContext context) {
    final voiced =
        doc.lines.where((l) => l.type == ScriptLineType.voiced).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.lg, AppSpacing.md, AppSpacing.xs),
          child: Row(children: [
            const Text('脚本',
                style: TextStyle(
                    fontSize: AppFontSize.emphasis,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(width: AppSpacing.sm),
            Text(voiced == 0 ? '${doc.lines.length} 行' : '$voiced 句台词',
                style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: AppFontSize.caption)),
          ]),
        ),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            itemCount: doc.lines.length,
            // onReorderItem 已经替调用方修正过「插入点」下标，直接透传
            onReorderItem: onMove,
            footer: _AppendLineButton(
                onTap: () => onInsertAfter(doc.lines.length - 1)),
            itemBuilder: (context, i) => _LineRow(
              key: ValueKey(doc.lines[i].id),
              index: i,
              line: doc.lines[i],
              voiceState: doc.voiceStateOf(doc.lines[i]),
              selected: i == selected,
              autofocus: doc.lines[i].id == autofocusLineId,
              deletable: doc.lines.length > 1,
              onSelect: () => onSelect(i),
              onSubmit: () => onInsertAfter(i),
              onRemove: () => onRemove(i),
              onTextChanged: (text) => onTextChanged(i, text),
            ),
          ),
        ),
      ],
    );
  }
}

/// 列表尾部的「新行」：写到底了不用回到最后一行按回车
class _AppendLineButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AppendLineButton({required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.lg),
        child: InkWell(
          key: const ValueKey('script-append-line'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
            child: Row(mainAxisSize: MainAxisSize.min, children: const [
              Icon(Icons.add, size: 14, color: AppColors.textTertiary),
              SizedBox(width: AppSpacing.xs),
              Text('新行',
                  style: TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.body)),
            ]),
          ),
        ),
      );
}

class _LineRow extends StatefulWidget {
  final int index;
  final ScriptLine line;

  /// 这一行配音的**有效**状态（doc.voiceStateOf 算好的）。
  /// 不用 line.voiceState 自己算：那个看不见基调变化，换了全片音色之后
  /// 点还是绿的，人以为都好了，导出才发现前后音色不一样
  final LineVoiceState voiceState;
  final bool selected;
  final bool autofocus;
  final bool deletable;
  final VoidCallback onSelect;
  final VoidCallback onSubmit;
  final VoidCallback onRemove;
  final ValueChanged<String> onTextChanged;

  const _LineRow({
    super.key,
    required this.index,
    required this.line,
    required this.voiceState,
    required this.selected,
    required this.autofocus,
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
  /// 用来判断「手是不是正在这一行上打字」。
  /// 外部改动同步进来时不能碰正在编辑的那一行——光标会被拽回开头
  final FocusNode _focus = FocusNode();

  late final TextEditingController _controller =
      TextEditingController(text: widget.line.text);
  bool _hovered = false;

  /// 还没写进文档的编辑。
  ///
  /// **不能每敲一个键就写文档**：那会让整个编导台重建一次，而中文输入法
  /// 在拼音阶段（composing）同样会触发 onChanged——组合状态被打断，
  /// 于是**中文根本打不出来**（真机上手写脚本时撞到）。
  /// 何况改台词还可能弹「划词的分镜要清掉」的确认框，打字打到一半
  /// 弹个对话框出来更是没法用。
  ///
  /// 所以照旁边那个字幕输入框的规矩来：**手停下来、或者离开这一行时才写**。
  Timer? _commitDebounce;
  String? _pending;

  @override
  void initState() {
    super.initState();
    // 手离开这一行就落盘：防抖没到点也算数
    _focus.addListener(() {
      if (!_focus.hasFocus) _commitNow();
    });
  }

  /// 把手上这一版写进文档。没有改动就什么都不做
  void _commitNow() {
    _commitDebounce?.cancel();
    final text = _pending;
    _pending = null;
    if (text == null) return;
    widget.onTextChanged(text);
  }

  /// 打字时只记在手上，停手一会儿再落盘。
  ///
  /// 一秒二是估出来的：中文输入法敲拼音、选词的间隔远比它短，
  /// 所以整个组合过程都不会被打断；而人真停下来时也不会觉得「没保存」
  void _onTyped(String text) {
    _pending = text;
    _commitDebounce?.cancel();
    _commitDebounce =
        Timer(const Duration(milliseconds: 1200), _commitNow);
  }

  @override
  void didUpdateWidget(covariant _LineRow old) {
    super.didUpdateWidget(old);
    // 外部改动（Agent 写台词、提取脚本覆盖、撤销）同步进输入框。
    //
    // 原来还要求 `line.id` 变过才更新，于是**同一行内容被外面改了根本不
    // 刷新**：真机上 Agent 写完台词，右栏的卡片变了、左栏这一列还是旧的，
    // 同一个界面上同一行显示着两个版本（验收 Agent 截图实锤）。
    //
    // 正在打字时不能动：光标会被拽回开头。所以用「有没有焦点」判断——
    // 手在这一行上就不碰，不在就同步
    if (widget.line.text != _controller.text && !_focus.hasFocus) {
      _controller.text = widget.line.text;
    }
  }

  @override
  void dispose() {
    // 这一行被拆掉之前把手上那一版写回去，别让人白打
    _commitNow();
    _commitDebounce?.cancel();
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visual = widget.line.type == ScriptLineType.visual;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        key: ValueKey('script-line-${widget.index}'),
        margin: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        decoration: BoxDecoration(
          color: widget.selected
              ? AppColors.surfaceRaised
              : (_hovered ? AppColors.surfaceRaised.withValues(alpha: 0.5)
                          : Colors.transparent),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 选中指示：左缘 2px 竖条（Apple 列表选中的惯用语汇）
            Container(
              width: 2,
              height: 34,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                color: widget.selected
                    ? AppColors.accentBlue
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            // 行号；hover 变拖柄（同一位置，不额外占宽）
            ReorderableDragStartListener(
              index: widget.index,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Container(
                  width: 30,
                  height: 36,
                  alignment: Alignment.center,
                  child: _hovered
                      ? const Icon(Icons.drag_indicator,
                          size: 13, color: AppColors.textTertiary)
                      : Text('${widget.index + 1}',
                          style: const TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: AppFontSize.caption,
                              fontFeatures: [FontFeature.tabularFigures()])),
                ),
              ),
            ),
            // 状态点：画面行空心；配音行按配音状态着色——
            // 灰 = 还没生成，绿 = 配音是最新的，橙 = 台词改了配音还是旧的
            Padding(
              padding: const EdgeInsets.only(top: 15),
              child: Tooltip(
                message: visual
                    ? '画面行'
                    : switch (widget.voiceState) {
                        LineVoiceState.none => '还没生成配音',
                        LineVoiceState.fresh => '配音已生成',
                        LineVoiceState.stale => '内容已改，配音是旧的',
                      },
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: visual
                        ? Colors.transparent
                        : switch (widget.voiceState) {
                            LineVoiceState.none => AppColors.textSecondary,
                            LineVoiceState.fresh => AppColors.green,
                            LineVoiceState.stale => AppColors.orange,
                          },
                    border: Border.all(
                        color: visual
                            ? AppColors.textTertiary
                            : Colors.transparent),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: TextEditingKeys(
                // 空格归输入法：被全页快捷键截成「播放」的话，拼音永远上不了屏
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  maxLines: null,
                  autofocus: widget.autofocus,
                  textInputAction: TextInputAction.done,
                  onTap: widget.onSelect,
                  onChanged: _onTyped,
                  onSubmitted: (_) {
                    _commitNow();
                    widget.onSubmit();
                  },
                  cursorColor: AppColors.accentBlue,
                  style: const TextStyle(
                      fontSize: AppFontSize.emphasis,
                      height: 1.55,
                      color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: visual ? '画面行（无台词，只有画面）' : null,
                    hintStyle: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: AppFontSize.emphasis),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  ),
                ),
              ),
            ),
            // 删除藏在 hover 里：写作时不该有一排叉常驻在眼前
            SizedBox(
              width: 28,
              height: 36,
              child: _hovered && widget.deletable
                  ? IconButton(
                      key: ValueKey('script-line-remove-${widget.index}'),
                      padding: EdgeInsets.zero,
                      iconSize: 13,
                      onPressed: widget.onRemove,
                      icon: const Icon(Icons.close,
                          color: AppColors.textTertiary),
                      tooltip: '删除这一行',
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
