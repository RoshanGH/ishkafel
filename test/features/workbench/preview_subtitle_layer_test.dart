import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';
import 'package:ishkafel/features/workbench/preview_subtitle_layer.dart';

/// 预览画面上的字幕层：跟着播放位置走，跟着样式走，**不碰播放器**。
void main() {
  Future<void> pump(WidgetTester tester,
      {required ValueNotifier<int> at,
      required String? Function(int) textAt,
      SubtitleStyle style = SubtitleStyle.standard,
      ValueChanged<double>? onDragEnd}) async {
    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: 360,
        height: 640,
        child: PreviewSubtitleLayer(
          positionMs: at,
          textAt: textAt,
          style: style,
          onDragEnd: onDragEnd,
        ),
      ),
    ));
  }

  testWidgets('播到哪儿就画哪一句', (tester) async {
    final at = ValueNotifier<int>(0);
    await pump(tester,
        at: at, textAt: (ms) => ms < 1500 ? '感染的白色念珠菌' : '记得每周消毒');

    // 描边一层、填充一层，两个 Text 是同一行字
    expect(find.text('感染的白色念珠菌'), findsWidgets);

    at.value = 2000;
    await tester.pump();

    expect(find.text('感染的白色念珠菌'), findsNothing);
    expect(find.text('记得每周消毒'), findsWidgets);
  });

  testWidgets('这一镜不该出字就一个字都不画——没换过的镜头字在原素材里', (tester) async {
    final at = ValueNotifier<int>(0);
    await pump(tester, at: at, textAt: (_) => null);

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('改字号立刻重画，不用等任何东西', (tester) async {
    final at = ValueNotifier<int>(0);
    await pump(tester,
        at: at,
        textAt: (_) => '这一句',
        style: const SubtitleStyle(fontRatio: 0.03));
    final small = tester
        .widgetList<Text>(find.text('这一句'))
        .first
        .style!
        .fontSize!;

    await pump(tester,
        at: at,
        textAt: (_) => '这一句',
        style: const SubtitleStyle(fontRatio: 0.06));
    final big =
        tester.widgetList<Text>(find.text('这一句')).first.style!.fontSize!;

    expect(big, greaterThan(small));
  });

  testWidgets('上下拖字幕：拖的过程中就动，松手才落盘', (tester) async {
    final at = ValueNotifier<int>(0);
    double? saved;
    await pump(tester,
        at: at, textAt: (_) => '拖我', onDragEnd: (r) => saved = r);

    final hit = find.byKey(const ValueKey('preview-subtitle-hit'));
    expect(hit, findsOneWidget);

    // 往上拖 64 逻辑像素 = 距底比例变大
    await tester.drag(hit, const Offset(0, -64));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!, greaterThan(SubtitleStyle.standard.bottomRatio));
  });
}
