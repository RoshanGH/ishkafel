import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/shot_allocation.dart';
import '../../core/script/word_pick.dart';

/// 台词上**划词建镜**：选中几个字 → 「用这几个字加分镜」。
///
/// 存在理由是一条真实的痛：一句话过三个分镜时，人得自己听、自己数
/// 「如果你觉得有点贵」读了几秒，再手动把镜头时长调成那个秒数。
/// 划词之后这一步没了——选中的字读多久，那一镜就多长。
///
/// **已经被某一镜占住的字根本划不了**：选中它不会出现按钮。人不做无效
/// 操作，比做完了再被拒绝好；想改就删掉那一镜，那几个字自动恢复可划。
class LineTextPicker extends StatefulWidget {
  final String text;

  /// 逐字时间戳。空 = 还没配音，划不了
  final List<VoiceWord> words;

  /// 已经被镜头占住的字区间（词序号）
  final List<WordRange> takenWordRanges;

  /// 选好了：给出**词序号**区间 `[start, end)`
  final void Function(int start, int end) onPick;

  /// 在台词上单纯点了一下（没划出选区）。
  ///
  /// **必须转出去**：可选文本会把点击吃掉，不冒泡到外层的行卡片。
  /// 真机上就是这样——划过词的那一行再点它，预览不跳了，其他行都正常，
  /// 因为只有选中的行才是可选文本
  final VoidCallback? onTapText;

  const LineTextPicker({
    super.key,
    required this.text,
    required this.words,
    required this.takenWordRanges,
    required this.onPick,
    this.onTapText,
  });

  @override
  State<LineTextPicker> createState() => LineTextPickerState();
}

class LineTextPickerState extends State<LineTextPicker> {
  /// 当前选区（字符位置）
  int? _from;
  int? _to;

  late List<CharRange> _taken =
      takenCharRanges(widget.text, widget.words, widget.takenWordRanges);

  @override
  void didUpdateWidget(LineTextPicker old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text ||
        old.words != widget.words ||
        old.takenWordRanges != widget.takenWordRanges) {
      _taken =
          takenCharRanges(widget.text, widget.words, widget.takenWordRanges);
      _from = null;
      _to = null;
    }
  }

  /// 测试用：模拟一次选区变化。**走的是和真机同一条路径**——
  /// 直接改字段的话，「点击要转出去」这类行为就测不到了
  @visibleForTesting
  void debugSelect(int from, int to) =>
      _onSelection(TextSelection(baseOffset: from, extentOffset: to));

  void _onSelection(TextSelection selection) {
    setState(() {
      _from = selection.start;
      _to = selection.end;
    });
    // 收起的选区 = 单纯点了一下，把它当成「点这一行」转出去
    if (selection.isCollapsed) widget.onTapText?.call();
  }

  /// 这一段能不能划：有选区、有逐字时间、没碰到已占用的字
  WordRange? get _pickable {
    final from = _from;
    final to = _to;
    if (from == null || to == null || to <= from) return null;
    if (widget.words.isEmpty) return null;
    if (overlapsTaken(_taken, from, to)) return null;
    return wordRangeOf(widget.text, widget.words, from, to);
  }

  @override
  Widget build(BuildContext context) {
    final pick = _pickable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText.rich(
          TextSpan(children: _spans()),
          style: const TextStyle(
              fontSize: AppFontSize.body,
              height: 1.5,
              color: AppColors.textPrimary),
          onSelectionChanged: (selection, _) => _onSelection(selection),
        ),
        if (pick != null) _addShotBar(pick),
        // 划不了的时候要说清为什么——不然人反复选却什么都不出现
        if (pick == null && _hasSelection && widget.words.isEmpty)
          _hint('这一句还没有配音，划词要靠逐字时间——先生成配音'),
        if (pick == null && _hasSelection && widget.words.isNotEmpty)
          _hint('这几个字里有一部分已经有画面了。想改就先删掉那一镜'),
      ],
    );
  }

  bool get _hasSelection =>
      _from != null && _to != null && _to! > _from!;

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(text,
            key: const Key('pick-hint'),
            style: const TextStyle(
                fontSize: AppFontSize.micro, color: AppColors.textTertiary)),
      );

  Widget _addShotBar(WordRange pick) {
    final count = pick.end - pick.start;
    final span = wordSpanMs(widget.words, pick.start, pick.end);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(children: [
        FilledButton.icon(
          key: const Key('pick-add-shot'),
          onPressed: () => widget.onPick(pick.start, pick.end),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: 4),
            textStyle: const TextStyle(fontSize: AppFontSize.caption),
          ),
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 14),
          label: const Text('用这几个字加分镜'),
        ),
        const SizedBox(width: AppSpacing.sm),
        // 说清这一镜会拿到什么、有多长——别让人凭感觉划
        Text(
            '$count 个字'
            '${span == null ? '' : ' · ${(span / 1000).toStringAsFixed(1)} 秒'}',
            style: const TextStyle(
                fontSize: AppFontSize.micro, color: AppColors.textSecondary)),
      ]),
    );
  }

  /// 把台词切成一段段：已占用的加底色，其余照常
  List<TextSpan> _spans() {
    if (_taken.isEmpty) return [TextSpan(text: widget.text)];
    final sorted = [..._taken]..sort((a, b) => a.start.compareTo(b.start));
    final out = <TextSpan>[];
    var pos = 0;
    for (final t in sorted) {
      final start = t.start.clamp(0, widget.text.length);
      final end = t.end.clamp(0, widget.text.length);
      if (start > pos) {
        out.add(TextSpan(text: widget.text.substring(pos, start)));
      }
      if (end > start) {
        out.add(TextSpan(
          text: widget.text.substring(start, end),
          style: TextStyle(
            backgroundColor: AppColors.accentBlue.withValues(alpha: 0.18),
            color: AppColors.textSecondary,
          ),
        ));
      }
      pos = end > pos ? end : pos;
    }
    if (pos < widget.text.length) {
      out.add(TextSpan(text: widget.text.substring(pos)));
    }
    return out;
  }
}
