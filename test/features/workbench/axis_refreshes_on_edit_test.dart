import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/inspector_panel.dart';

/// **逐帧微调之后，属性栏上的数字要跟着变。**
///
/// 2026-09-08 我自己传视频回归时点出来的：连点三次「开始 +1 帧」，盘上确实
/// 走了 3 帧，属性栏却只动了 1 帧。
///
/// 根因：成片时间轴是在 WorkbenchBody 的 build 里算一次再传下来的，而微调
/// 只 `notifyListeners()`——各个面板自己的 AnimatedBuilder 重建了，拿到的
/// 却是上一次外层 build 捕获的**旧轴**。数字于是停在改动之前。
///
/// 这正是产品负责人反复撞见的那一类：「改了没反应」。轴必须在面板自己的
/// 重建里现算（实测全量重算 0.4µs，不是性能问题）。
void main() {
  late SegmentationEditorController controller;

  setUp(() {
    controller = SegmentationEditorController(
      initialUnits: const [
        SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 5000,
            transcript: '第一句',
            shots: [Shot(startMs: 0, endMs: 5000)]),
        SemanticUnit(
            index: 1,
            startMs: 5000,
            endMs: 12000,
            transcript: '第二句',
            shots: [Shot(startMs: 5000, endMs: 12000)]),
      ],
      durationMs: 12000,
      fps: 30,
      sentences: const [],
    );
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          height: 900,
          child: InspectorPanel(
            controller: controller,
            fps: 30,
            onSplitAtPlayhead: () {},
            onSeekTo: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('连点三次「+1 帧」，属性栏走满三帧', (tester) async {
    await pump(tester);
    controller.select(const EditorSelection.unit(1));
    await tester.pumpAndSettle();

    // U2 起点 5000ms = 第 150 帧 = 00:05.00
    expect(find.text('00:05.00'), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      controller.nudgeSelectedEdge(startEdge: true, frames: 1);
      await tester.pumpAndSettle();
    }

    // 走 3 帧 → 第 153 帧 = 00:05.03
    expect(find.text('00:05.03'), findsOneWidget,
        reason: '真机上这里停在 00:05.01——面板重建了，轴却还是旧的');
  });

  testWidgets('一次一帧也要跟上，不是只有整批操作才刷新', (tester) async {
    await pump(tester);
    controller.select(const EditorSelection.unit(1));
    await tester.pumpAndSettle();

    controller.nudgeSelectedEdge(startEdge: true, frames: 1);
    await tester.pumpAndSettle();

    expect(find.text('00:05.01'), findsOneWidget);
  });
}
