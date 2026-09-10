import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/features/workbench/unit_list_panel.dart';

List<SemanticUnit> _fixtureUnits() => [
      const SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '第一句台词很长很长很长很长需要省略号',
        tags: ['痛点引入'],
      ),
      const SemanticUnit(
        index: 1,
        startMs: 2000,
        endMs: 4000,
        transcript: '第二句台词',
        tags: ['产品引入'],
      ),
    ];

void main() {
  testWidgets('渲染每行 U{n}、时间区间、台词与标签', (tester) async {
    final controller = SegmentationEditorController(
      initialUnits: _fixtureUnits(),
      durationMs: 4000,
      fps: 30,
      sentences: const [],
    );

    await tester.pumpWidget(MaterialApp(
      home: Material(child: UnitListPanel(controller: controller)),
    ));

    expect(find.textContaining('U1'), findsOneWidget);
    expect(find.textContaining('U2'), findsOneWidget);
    expect(find.textContaining('痛点引入'), findsOneWidget);
    expect(find.textContaining('产品引入'), findsOneWidget);
  });

  testWidgets('点击行触发 controller.select 与 onUnitTap 回调', (tester) async {
    final controller = SegmentationEditorController(
      initialUnits: _fixtureUnits(),
      durationMs: 4000,
      fps: 30,
      sentences: const [],
    );
    SemanticUnit? tapped;

    await tester.pumpWidget(MaterialApp(
      home: Material(
        child: UnitListPanel(
          controller: controller,
          onUnitTap: (u) => tapped = u,
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('unit-row-1')));
    await tester.pump();

    expect(controller.selection?.unitIndex, 1);
    expect(controller.selection?.shotIndex, isNull);
    expect(tapped?.index, 1);
  });

  /// 选中的那一行要比别的行**明显**——不只是「有底色」。
  ///
  /// 2026-09-10 起未选中的行也有底了（原来全透明，一列下来只有文字飘着，
  /// 看不出一行到哪儿为止），所以这条用例改成比对两者的差别。
  testWidgets('选中行比未选中行更亮、更蓝，还带一圈发光', (tester) async {
    final controller = SegmentationEditorController(
      initialUnits: _fixtureUnits(),
      durationMs: 4000,
      fps: 30,
      sentences: const [],
    );
    controller.select(const EditorSelection.unit(0));

    await tester.pumpWidget(MaterialApp(
      home: Material(child: UnitListPanel(controller: controller)),
    ));
    await tester.pumpAndSettle();

    BoxDecoration decoOf(int i) =>
        (tester.widget<AnimatedContainer>(
                find.byKey(Key('unit-row-container-$i'))).decoration
            as BoxDecoration);

    final selected = decoOf(0);
    final other = decoOf(1);

    expect(selected.color!.b, greaterThan(other.color!.b),
        reason: '选中态该是蓝的');
    expect(selected.boxShadow, isNotNull,
        reason: '选中的那一行要有一圈发光，扫一眼就能找到自己在哪');
    expect(other.color!.a, greaterThan(0),
        reason: '未选中的行也要有底——全透明的话看不出「一行」到哪儿为止');
  });
}
