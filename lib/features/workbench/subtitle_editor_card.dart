import 'package:flutter/material.dart';

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
class SubtitleEditorCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (!replaced) return const SizedBox.shrink();
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
              // 用 controller 而不是 initialValue：外面改了（比如点了「改回
              // 自动」）这里要跟着变，只给初值的话框里还留着旧文字
              controller: TextEditingController(text: lines[i].text)
                ..selection =
                    TextSelection.collapsed(offset: lines[i].text.length),
              style: const TextStyle(fontSize: AppFontSize.caption),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => onChanged([
                for (var j = 0; j < lines.length; j++)
                  if (j == i)
                    SubtitleLine(
                        startMs: lines[j].startMs,
                        endMs: lines[j].endMs,
                        text: v)
                  else
                    lines[j],
              ]),
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
