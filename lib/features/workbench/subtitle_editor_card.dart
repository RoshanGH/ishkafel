import 'package:flutter/material.dart';
import '../../core/ui/text_editing_keys.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/subtitle/subtitle_overlay.dart';
import 'inspector_widgets.dart';

/// 这一镜要烧上去的字幕，可以手改。
///
/// **只有换过素材的镜头才有**：没换的那些字幕烧在原片像素里，我们既读不出
/// 也不重渲，摆个编辑框只会让人以为改得动。
///
/// 为什么需要手改：字幕默认按 ASR 的**词级时间戳**切给各镜，而「哪里断句
/// 好看」是编导的判断，规则算不对——真机上「了」这个字的声音落在下一镜，
/// 于是那一镜的字幕就以一个孤零零的「了」开头。ASR 没错、切点也没错，
/// 只是没人能替编导决定这个字归哪句。
///
/// **字幕是字幕，台词是台词**：改这里不动单元的台词，打标、检索、换音色
/// 照旧用台词。
class SubtitleEditorCard extends StatefulWidget {
  /// 这一镜换过素材没有
  final bool replaced;

  /// 当前这一镜的字幕（手改过就是手改的，否则是按 ASR 算出来的那份）
  final List<SubtitleLine> lines;

  /// 是不是手改过（改过才给「改回自动」，并标出来）
  final bool edited;

  final ValueChanged<List<SubtitleLine>> onChanged;

  /// 清掉手改，回到按 ASR 自动算
  final VoidCallback onResetToAuto;

  const SubtitleEditorCard({
    super.key,
    required this.replaced,
    required this.lines,
    required this.edited,
    required this.onChanged,
    required this.onResetToAuto,
  });

  @override
  State<SubtitleEditorCard> createState() => _SubtitleEditorCardState();
}

class _SubtitleEditorCardState extends State<SubtitleEditorCard> {
  /// 每一行一个**长期持有**的 controller。
  ///
  /// 曾经在 build 里现造（`TextEditingController(text: ...)`），中文就此打不
  /// 进去：输入法要先把拼音摆在候选区（composing）、选好字才上屏，而每敲一个
  /// 字母都会 onChanged → 父层重建 → 新 controller，候选区当场被清掉。粘贴是
  /// 一次性整段塞进来、不经过候选区，所以只有粘贴是好的——用户就是这么描述的。
  final List<TextEditingController> _controllers = [];

  /// 每一行一个焦点节点：**离开这一格才提交**。
  ///
  /// 敲字的过程中提交，等于每敲一个字重烧一次字幕——一句十来个字就是十来次
  /// ffmpeg，横幅一直在闪，而中间那些半截状态（「李」「李斯」「李斯特」…）
  /// 没有任何意义。用户原话：「我每键入一下，它都会提示那个正在烧录。
  /// 这个东西我觉得可以在我修改完光标离开的时候，你再去进行烧录会好一点。」
  final List<FocusNode> _focus = [];

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(SubtitleEditorCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// 让 controller 的条数与内容跟上外面那份数据。
  ///
  /// **文字相同就一个字都不碰**：碰了就会把光标推到末尾、把候选区清掉。
  /// 人正在敲的那一行，走的正是「相同」这条路——他敲的字已经通过 onChanged
  /// 传出去又传回来了。
  void _sync() {
    final lines = widget.lines;
    while (_controllers.length < lines.length) {
      final i = _controllers.length;
      _controllers.add(TextEditingController());
      _focus.add(FocusNode()..addListener(() => _commitIfLeft(i)));
    }
    while (_controllers.length > lines.length) {
      _controllers.removeLast().dispose();
      _focus.removeLast().dispose();
    }
    for (var i = 0; i < lines.length; i++) {
      if (_controllers[i].text == lines[i].text) continue;
      _controllers[i].value = TextEditingValue(
        text: lines[i].text,
        selection: TextSelection.collapsed(offset: lines[i].text.length),
      );
    }
  }

  /// 焦点离开第 [i] 格：把框里的文字交出去。没改过就不交——白交一次等于
  /// 白烧一次
  void _commitIfLeft(int i) {
    if (i >= _focus.length || _focus[i].hasFocus) return;
    if (i >= widget.lines.length || i >= _controllers.length) return;
    final text = _controllers[i].text;
    if (text == widget.lines[i].text) return;
    widget.onChanged([
      for (var j = 0; j < widget.lines.length; j++)
        if (j == i)
          SubtitleLine(
              startMs: widget.lines[j].startMs,
              endMs: widget.lines[j].endMs,
              text: text)
        else
          widget.lines[j],
    ]);
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focus) {
      f.dispose();
    }
    super.dispose();
  }

  List<SubtitleLine> get lines => widget.lines;
  bool get edited => widget.edited;
  ValueChanged<List<SubtitleLine>> get onChanged => widget.onChanged;
  VoidCallback get onResetToAuto => widget.onResetToAuto;

  @override
  Widget build(BuildContext context) {
    if (!widget.replaced) return const SizedBox.shrink();
    return inspectorCard([
      Row(children: [
        inspectorLabel('这一镜的字幕'),
        const Spacer(),
        if (edited)
          const Text('手改过',
              style: TextStyle(
                  fontSize: AppFontSize.micro, color: AppColors.accentBlue)),
      ]),
      const SizedBox(height: 4),
      const Text('换过素材的镜头，原片的字跟着旧画面一起没了，这里的字会重新烧上去',
          style: TextStyle(
              fontSize: AppFontSize.caption,
              height: 1.5,
              color: AppColors.textTertiary)),
      const SizedBox(height: AppSpacing.sm),
      for (var i = 0; i < lines.length; i++) _row(i),
      const SizedBox(height: AppSpacing.xs),
      Row(children: [
        TextButton(
          key: const ValueKey('subtitle-add'),
          onPressed: _add,
          style: _compact,
          child: const Text('＋ 加一段',
              style: TextStyle(fontSize: AppFontSize.caption)),
        ),
        const Spacer(),
        // 没改过就不摆——本来就是自动的，点了没意义
        if (edited)
          TextButton(
            key: const ValueKey('subtitle-reset'),
            onPressed: onResetToAuto,
            style: _compact,
            child: const Text('改回自动',
                style: TextStyle(fontSize: AppFontSize.caption)),
          ),
      ]),
    ]);
  }

  static final _compact = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap);

  Widget _row(int i) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(
            width: 76,
            child: Text(
              '${_sec(lines[i].startMs)}→${_sec(lines[i].endMs)}',
              style: const TextStyle(
                  fontSize: AppFontSize.micro, color: AppColors.textTertiary),
            ),
          ),
          Expanded(
            child: TextField(
              key: ValueKey('subtitle-text-$i'),
              // 长期持有的那一个，见 [_sync]。绝不在 build 里现造
              controller: _controllers[i],
              focusNode: _focus[i],
              style: const TextStyle(fontSize: AppFontSize.caption),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                border: OutlineInputBorder(),
              ),
              // **不在这里提交**：敲字的过程中每次提交都要重烧一遍字幕。
              // 光标离开这一格时才交（见 [_commitIfLeft]）；回车也算改完
              onSubmitted: (_) => _commitIfLeft(i),
              // 点到别处就交出焦点：既把这一格提交掉，也把空格还给播放/暂停
              onTapOutside: releaseFocusOnTapOutside,
            ),
          ),
          IconButton(
            key: ValueKey('subtitle-remove-$i'),
            onPressed: () => onChanged([
              for (var j = 0; j < lines.length; j++)
                if (j != i) lines[j],
            ]),
            icon: const Icon(Icons.close, size: 14),
            color: AppColors.textTertiary,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            tooltip: '删掉这一段',
          ),
        ]),
      );

  /// 加一段：接在最后一段后面，长度给 1 秒。时间可以在时间线上再调
  void _add() {
    final start = lines.isEmpty ? 0 : lines.last.endMs;
    onChanged([
      ...lines,
      SubtitleLine(startMs: start, endMs: start + 1000, text: ''),
    ]);
  }

  static String _sec(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';
}
