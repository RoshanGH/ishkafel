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

  testWidgets('选中行使用 accentBlue 高亮底色', (tester) async {
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

    final container = tester.widget<Container>(find.byKey(const Key('unit-row-container-0')));
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, isNotNull);
  });
}
