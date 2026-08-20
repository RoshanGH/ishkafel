import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/subtitle/subtitle_style.dart';

/// 预览舞台上的实时字幕层：播放到哪一句，字幕就是那一句——
/// 位置、字号、颜色、形态（描边/黑条/毛玻璃）即改即见。
///
/// 与成片的对齐方式：用**同一套 [SubtitleStyle] 参数映射**画——
/// 字号 = fontRatio × 画面高、底边距 = bottomRatio × 画面高、
/// 描边粗细与衬底透明度都照抄导出侧（subtitle_rasterizer 的 spec）。
/// 渲染引擎不同（这里是 Flutter，成片是 CoreText+ffmpeg），像素级
/// 会有细微出入，但位置/大小/形态这些决定观感的量是一致的。
class PreviewSubtitle extends StatelessWidget {
  final String text;
  final SubtitleStyle style;

  const PreviewSubtitle({super.key, required this.text, required this.style});

  Color get _fill {
    final hex = style.colorHex;
    if (hex != null) return Color(int.parse('FF$hex', radix: 16));
    return switch (style.preset) {
      SubtitlePreset.yellowOutline => const Color(0xFFFFD900),
      _ => Colors.white,
    };
  }

  bool get _hasBacking =>
      style.preset == SubtitlePreset.whiteBox ||
      style.preset == SubtitlePreset.blurBox;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, constraints) {
      final h = constraints.maxHeight;
      final fontSize = h * style.fontRatio;
      // 导出侧 marginV 是字幕**底边**距画面底的距离，这里用 bottom 对齐
      final bottom = h * style.bottomRatio;
      // 描边占字号百分比与导出 spec 一致：有衬底收细
      final stroke = fontSize * (_hasBacking ? 0.03 : 0.09);
      final textStyle = TextStyle(
        fontSize: fontSize,
        height: 1.25,
        fontWeight: FontWeight.w600,
        color: _fill,
      );
      Widget label = Stack(children: [
        if (stroke > 0)
          Text(text,
              textAlign: TextAlign.center,
              style: textStyle.copyWith(
                color: null,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = stroke * 2
                  ..strokeJoin = StrokeJoin.round
                  ..color = Colors.black,
              )),
        Text(text, textAlign: TextAlign.center, style: textStyle),
      ]);
      if (style.preset == SubtitlePreset.whiteBox) {
        label = Container(
          padding: EdgeInsets.symmetric(
              horizontal: fontSize * 0.5, vertical: fontSize * 0.22),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(fontSize * 0.18),
          ),
          child: label,
        );
      } else if (style.preset == SubtitlePreset.blurBox) {
        // 毛玻璃：把字幕背后那块**画面**磨砂——预览用 BackdropFilter
        // 近似成片的 boxblur
        label = ClipRRect(
          borderRadius: BorderRadius.circular(fontSize * 0.18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: fontSize * 0.5, vertical: fontSize * 0.22),
              color: Colors.white.withValues(alpha: 0.06),
              child: label,
            ),
          ),
        );
      }
      return IgnorePointer(
        child: Padding(
          padding: EdgeInsets.only(
              bottom: bottom, left: fontSize, right: fontSize),
          child: Align(alignment: Alignment.bottomCenter, child: label),
        ),
      );
    });
  }
}
