import 'package:flutter/material.dart';

import '../../app/theme/app_spacing.dart';

import '../../app/theme/app_colors.dart';
import '../../core/subtitle/subtitle_overlay.dart';
import 'subtitle_editor_card.dart';
import 'subtitle_popover_place.dart';

/// 双击时间线上的字幕块，就地把这一镜的字幕改掉。
///
/// 用户 2026-09-08：「我双击那个字幕轨上的那个字幕的时候，能不能在那个地方改？」
///
/// **为什么不是把块体本身变成输入框**：字幕轨只有 22px 高，窄镜头的块可能只有
/// 几十像素宽（现在小于 24px 连字都不画），而且一镜可能有好几行字幕——
/// 原地内嵌做不出能用的东西。所以弹一个定宽的浮层贴上去。
///
/// **内容直接复用右侧那张字幕卡**（[SubtitleEditorCard]）：两个入口共用一份
/// 实现，否则它们迟早行为不一样——一边离开才提交、另一边每敲一下就提交，
/// 这种差别人只会觉得「时好时坏」。
///
/// 关掉的方式：Esc、点浮层外。用 [showDialog] 是有意的——它自带这两样，
/// 而且开着的时候时间线动不了，不会出现「框在飞」。
Future<void> showSubtitlePopover(
  BuildContext context, {
  /// 字幕块在屏幕上的位置
  required Rect anchor,
  required List<SubtitleLine> lines,
  required bool edited,
  required ValueChanged<List<SubtitleLine>> onChanged,
  required VoidCallback onResetToAuto,
}) {
  const width = 340.0;
  return showDialog<void>(
    context: context,
    // 不压暗背景：人要一边改一边看时间线上那一块在哪儿
    barrierColor: Colors.transparent,
    builder: (dialogContext) {
      final screen = MediaQuery.sizeOf(dialogContext);
      final spot = placeSubtitlePopover(
          anchor: anchor, screen: screen, width: width);
      final card = Material(
        color: AppColors.surfaceRaised,
        elevation: 12,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: ConstrainedBox(
          // **不定死高度**：内容有几行是这里才知道的，估小了会把「加一段」
          // 挤到可视区外，点下去落到遮罩上、浮层直接关掉
          constraints: BoxConstraints(maxHeight: spot.maxHeight),
          child: SingleChildScrollView(
            child: _Live(
              lines: lines,
              edited: edited,
              onChanged: onChanged,
              onResetToAuto: () {
                onResetToAuto();
                Navigator.of(dialogContext).pop();
              },
            ),
          ),
        ),
      );
      return Stack(children: [
        Positioned(
          left: spot.left,
          top: spot.top,
          bottom: spot.bottom,
          width: width,
          // 摆在上方时用下边定位，内容变多往上长，不会离开块体；
          // 这时要让 Column 贴着底部，否则它会撑满整个 bottom 约束
          child: spot.isAbove
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [Flexible(child: card)])
              : card,
        ),
      ]);
    },
  );
}

/// 浮层里那份数据要跟着改动更新：外面传进来的是打开那一刻的快照，
/// 加一段、删一段之后不自己更新的话，框里还是旧的
class _Live extends StatefulWidget {
  final List<SubtitleLine> lines;
  final bool edited;
  final ValueChanged<List<SubtitleLine>> onChanged;
  final VoidCallback onResetToAuto;

  const _Live({
    required this.lines,
    required this.edited,
    required this.onChanged,
    required this.onResetToAuto,
  });

  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  late List<SubtitleLine> _lines = widget.lines;

  @override
  Widget build(BuildContext context) => SubtitleEditorCard(
        replaced: true,
        lines: _lines,
        edited: true,
        onChanged: (v) {
          setState(() => _lines = v);
          widget.onChanged(v);
        },
        onResetToAuto: widget.onResetToAuto,
      );
}
