import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/unit_list_panel.dart';

SegmentationEditorController _controller() => SegmentationEditorController(
      initialUnits: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 4000,
          transcript: '第一句台词',
          shots: [
            Shot(startMs: 0, endMs: 1000),
            Shot(startMs: 1000, endMs: 2500),
            Shot(startMs: 2500, endMs: 4000),
          ],
        ),
        SemanticUnit(
          index: 1,
          startMs: 4000,
          endMs: 8000,
          transcript: '第二句台词',
          shots: [Shot(startMs: 4000, endMs: 8000)],
        ),
      ],
      durationMs: 8000,
      fps: 30,
      sentences: const [],
    );

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SizedBox(width: 320, child: child))),
    );

void main() {
  group('左栏信息密度（对标设计定稿：编号/时间/台词之外还要有可扫读的结构信息）',
      () {
    testWidgets('列表头给出单元总数，用户不用自己数', (tester) async {
      await _pump(tester, UnitListPanel(controller: _controller()));

      expect(find.text('台词语义单元'), findsOneWidget,
          reason: '两层结构里这是第一层，列表要标明自己是哪一层');
      expect(find.text('2 个'), findsOneWidget);
    });

    testWidgets('每行显示该单元包含多少个视觉镜头', (tester) async {
      await _pump(tester, UnitListPanel(controller: _controller()));

      expect(find.text('3 镜头'), findsOneWidget,
          reason: '镜头数是判断这个单元要不要展开细调的关键信息，'
              '设计定稿在每行都标了它');
      expect(find.text('1 镜头'), findsOneWidget);
    });

    testWidgets('列表头随拆分/合并实时更新计数', (tester) async {
      final controller = _controller();
      await _pump(tester, UnitListPanel(controller: controller));
      expect(find.text('2 个'), findsOneWidget);

      controller.select(const EditorSelection.unit(0));
      controller.splitSelectedAt(2000);
      await tester.pump();

      expect(find.text('3 个'), findsOneWidget,
          reason: '计数写死或不监听 controller 时这里会停在 2');
    });
  });
}
