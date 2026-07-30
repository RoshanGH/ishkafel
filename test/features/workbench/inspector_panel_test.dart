import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/inspector_panel.dart';

const _fps = 30.0;

List<SemanticUnit> _fixtureUnits() => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '第一句台词',
        tags: const ['痛点引入'],
        shots: const [
          Shot(startMs: 0, endMs: 1000, tags: ['特写']),
          Shot(startMs: 1000, endMs: 2000, tags: ['全景']),
        ],
      ),
      SemanticUnit(
        index: 1,
        startMs: 2000,
        endMs: 4000,
        transcript: '第二句台词',
        tags: const ['产品引入'],
        shots: const [
          Shot(startMs: 2000, endMs: 4000, tags: ['产品特写']),
        ],
      ),
    ];

SegmentationEditorController _fixtureController({EditorSelection? selection}) {
  final controller = SegmentationEditorController(
    initialUnits: _fixtureUnits(),
    durationMs: 4000,
    fps: _fps,
    sentences: const [],
  );
  if (selection != null) controller.select(selection);
  return controller;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Material(child: child)));
}

void main() {
  group('formatTimecode', () {
    test('formatTimecode(70033, 30) == 01:10.01', () {
      expect(formatTimecode(70033, 30), '01:10.01');
    });

    test('formatTimecode(0, 30) == 00:00.00', () {
      expect(formatTimecode(0, 30), '00:00.00');
    });
  });

  group('InspectorPanel', () {
    testWidgets('无选中时显示占位文案', (tester) async {
      final controller = _fixtureController();
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      expect(find.textContaining('未选中'), findsOneWidget);
    });

    testWidgets('选中单元时显示标题、时间码与台词', (tester) async {
      final controller =
          _fixtureController(selection: const EditorSelection.unit(0));
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      expect(find.textContaining('U1'), findsWidgets);
      expect(find.text(formatTimecode(0, _fps)), findsOneWidget);
      expect(find.text(formatTimecode(2000, _fps)), findsOneWidget);

      final field = tester.widget<TextField>(
          find.byKey(const Key('inspector-transcript-field')));
      expect(field.controller?.text, '第一句台词');
    });

    testWidgets('点击结束边界「＋」步进后 controller.units 对应边界 +1 帧', (tester) async {
      final controller =
          _fixtureController(selection: const EditorSelection.unit(0));
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      final beforeEnd = controller.units[0].endMs;
      await tester.tap(find.byKey(const Key('inspector-end-plus')));
      await tester.pump();

      final frameMs = (1000 / _fps).round();
      expect(controller.units[0].endMs, beforeEnd + frameMs);
    });

    testWidgets('台词编辑通过 TextField onChanged 回写 controller', (tester) async {
      final controller =
          _fixtureController(selection: const EditorSelection.unit(1));
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      await tester.enterText(
          find.byKey(const Key('inspector-transcript-field')), '改后的台词');
      await tester.pump();

      expect(controller.units[1].transcript, '改后的台词');
    });

    testWidgets('选中镜头时显示所属单元与镜头信息', (tester) async {
      final controller = _fixtureController(
          selection: const EditorSelection.shot(0, 1));
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      expect(find.textContaining('U1'), findsWidgets);
      expect(find.textContaining('S2'), findsWidgets);
      expect(find.textContaining('全景'), findsOneWidget);
    });

    testWidgets('「✂ 在游标处拆分」触发 onSplitAtPlayhead 回调', (tester) async {
      final controller =
          _fixtureController(selection: const EditorSelection.unit(0));
      var splitCalled = false;
      await _pump(
        tester,
        InspectorPanel(
          controller: controller,
          fps: _fps,
          onSplitAtPlayhead: () => splitCalled = true,
        ),
      );

      await tester.tap(find.byKey(const Key('inspector-split-btn')));
      await tester.pump();

      expect(splitCalled, isTrue);
    });

    testWidgets('「⇧ 并入上一单元」调用 controller.mergeSelectedWithPrevious', (tester) async {
      final controller =
          _fixtureController(selection: const EditorSelection.unit(1));
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      await tester.tap(find.byKey(const Key('inspector-merge-btn')));
      await tester.pump();

      expect(controller.units.length, 1);
      expect(controller.units[0].transcript, contains('第一句台词'));
    });

    group('readOnly（评审 Important 1：回看模式不可编辑）', () {
      testWidgets('单元步进按钮均禁用', (tester) async {
        final controller =
            _fixtureController(selection: const EditorSelection.unit(1));
        await _pump(
          tester,
          InspectorPanel(controller: controller, fps: _fps, readOnly: true),
        );

        final startMinus = tester.widget<InkWell>(
            find.byKey(const Key('inspector-start-minus')));
        final startPlus = tester
            .widget<InkWell>(find.byKey(const Key('inspector-start-plus')));
        expect(startMinus.onTap, isNull);
        expect(startPlus.onTap, isNull);
      });

      testWidgets('台词 TextField 禁用', (tester) async {
        final controller =
            _fixtureController(selection: const EditorSelection.unit(0));
        await _pump(
          tester,
          InspectorPanel(controller: controller, fps: _fps, readOnly: true),
        );

        final field = tester.widget<TextField>(
            find.byKey(const Key('inspector-transcript-field')));
        expect(field.enabled, isFalse);
      });

      testWidgets('拆分/并入按钮禁用', (tester) async {
        final controller =
            _fixtureController(selection: const EditorSelection.unit(1));
        await _pump(
          tester,
          InspectorPanel(controller: controller, fps: _fps, readOnly: true),
        );

        final splitBtn =
            tester.widget<InkWell>(find.byKey(const Key('inspector-split-btn')));
        final mergeBtn =
            tester.widget<InkWell>(find.byKey(const Key('inspector-merge-btn')));
        expect(splitBtn.onTap, isNull);
        expect(mergeBtn.onTap, isNull);
      });

      testWidgets('镜头步进按钮同理禁用', (tester) async {
        final controller = _fixtureController(
            selection: const EditorSelection.shot(0, 1));
        await _pump(
          tester,
          InspectorPanel(controller: controller, fps: _fps, readOnly: true),
        );

        final endPlus = tester
            .widget<InkWell>(find.byKey(const Key('inspector-end-plus')));
        expect(endPlus.onTap, isNull);
      });
    });
  });
}
