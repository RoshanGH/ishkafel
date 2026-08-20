import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';
import 'package:ishkafel/features/director/preview_subtitle.dart';

/// 预览字幕层：与导出侧同一套 SubtitleStyle 映射——
/// 字号 = fontRatio×画面高、底距 = bottomRatio×画面高、四形态。
Future<void> pump(WidgetTester tester, SubtitleStyle style,
    {String text = '这是一句台词'}) async {
  await tester.pumpWidget(MaterialApp(
    home: Center(
      child: SizedBox(
        width: 270,
        height: 480,
        child: Stack(fit: StackFit.expand, children: [
          Container(color: Colors.black),
          PreviewSubtitle(text: text, style: style),
        ]),
      ),
    ),
  ));
}

void main() {
  testWidgets('字号与位置按画面高换算（和成片同一套参数）', (tester) async {
    await pump(tester,
        const SubtitleStyle(fontRatio: 0.05, bottomRatio: 0.25));

    final texts = tester.widgetList<Text>(find.text('这是一句台词'));
    expect(texts.length, 2, reason: '描边层 + 填充层两层');
    expect(texts.last.style!.fontSize, closeTo(480 * 0.05, 0.1),
        reason: '字号 = fontRatio × 画面高');
  });

  testWidgets('六色自定义字色生效；黄字预设是导出侧同款黄', (tester) async {
    await pump(tester, const SubtitleStyle(colorHex: 'FF453A'));
    var fill = tester.widgetList<Text>(find.text('这是一句台词')).last;
    expect(fill.style!.color, const Color(0xFFFF453A));

    await pump(tester,
        const SubtitleStyle(preset: SubtitlePreset.yellowOutline));
    fill = tester.widgetList<Text>(find.text('这是一句台词')).last;
    expect(fill.style!.color, const Color(0xFFFFD900),
        reason: '与导出 spec 的 (1.0,0.85,0.0) 一致');
  });

  testWidgets('三种形态：黑条有衬底、毛玻璃有背景模糊、描边无衬底',
      (tester) async {
    await pump(tester, const SubtitleStyle(preset: SubtitlePreset.whiteBox));
    expect(find.byType(BackdropFilter), findsNothing);
    final box = tester.widgetList<Container>(find.byType(Container)).where(
        (c) => (c.decoration as BoxDecoration?)?.color?.a != null &&
            ((c.decoration as BoxDecoration).color!.a) < 1);
    expect(box, isNotEmpty, reason: '黑底条是半透明衬底');

    await pump(tester, const SubtitleStyle(preset: SubtitlePreset.blurBox));
    expect(find.byType(BackdropFilter), findsOneWidget,
        reason: '毛玻璃 = 字幕背后那块画面被模糊');

    await pump(tester, const SubtitleStyle());
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('空文本不渲染任何东西', (tester) async {
    await pump(tester, const SubtitleStyle(), text: '  ');
    expect(find.byType(Text), findsNothing);
  });
}
