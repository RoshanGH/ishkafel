import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/edit_locks.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/inspector_panel.dart';

/// 钉住的那一段，界面上要「动不了 + 说得清」。
///
/// 只把按钮置灰而不说原因，用户只会以为软件坏了——所以旁边必须有一句
/// 点名是谁、为什么、怎么解开。
void main() {
  final units = [
    SemanticUnit(
      index: 0,
      startMs: 0,
      endMs: 6000,
      transcript: 'A',
      shots: const [
        Shot(startMs: 0, endMs: 2000),
        Shot(startMs: 2000, endMs: 4000),
        Shot(startMs: 4000, endMs: 6000),
      ],
    ),
    SemanticUnit(
      index: 1,
      startMs: 6000,
      endMs: 12000,
      transcript: 'B',
      shots: const [
        Shot(startMs: 6000, endMs: 9000),
        Shot(startMs: 9000, endMs: 12000),
      ],
    ),
  ];

  Future<SegmentationEditorController> pump(
    WidgetTester tester, {
    required EditLocks locks,
    required EditorSelection selection,
  }) async {
    final controller = SegmentationEditorController(
      initialUnits: units,
      durationMs: 12000,
      fps: 30,
      sentences: const [],
    )
      ..locks = locks
      ..select(selection);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 900,
          child: InspectorPanel(controller: controller, fps: 30),
        ),
      ),
    ));
    return controller;
  }

  bool enabled(WidgetTester tester, String key) {
    final widget = tester.widget(find.byKey(Key(key)));
    // 步进控件禁用时 onPressed/onTap 为 null
    if (widget is IconButton) return widget.onPressed != null;
    if (widget is InkWell) return widget.onTap != null;
    // 帧步进按钮（长按连发）：按下即触发，禁用时 onTapDown 为 null
    if (widget is GestureDetector) {
      return widget.onTap != null || widget.onTapDown != null;
    }
    return true;
  }

  testWidgets('挑过素材的镜头：两侧步进按钮都灰掉', (tester) async {
    await pump(tester,
        locks: EditLocks(shots: {const ShotRef(0, 1)}),
        selection: EditorSelection.shot(0, 1));
    expect(enabled(tester, 'inspector-start-minus'), isFalse);
    expect(enabled(tester, 'inspector-end-plus'), isFalse);
  });

  testWidgets('没挑过的镜头照常能调', (tester) async {
    await pump(tester,
        locks: EditLocks(shots: {const ShotRef(1, 0)}),
        selection: EditorSelection.shot(0, 1));
    expect(enabled(tester, 'inspector-start-minus'), isTrue);
    expect(enabled(tester, 'inspector-end-plus'), isTrue);
  });

  testWidgets('相邻镜头被钉，共用的那条边界也调不了', (tester) async {
    await pump(tester,
        locks: EditLocks(shots: {const ShotRef(0, 2)}),
        selection: EditorSelection.shot(0, 1));
    expect(enabled(tester, 'inspector-end-plus'), isFalse,
        reason: 'S2 的结束就是 S3 的开始');
    expect(enabled(tester, 'inspector-start-minus'), isTrue,
        reason: 'S2 的开始与 S3 无关，不该跟着锁死');
  });

  testWidgets('灰掉的同时把原因说清楚，并告诉用户怎么解开', (tester) async {
    await pump(tester,
        locks: EditLocks(shots: {const ShotRef(0, 1)}),
        selection: EditorSelection.shot(0, 1));
    expect(find.textContaining('切分已锁定'), findsOneWidget);
    expect(find.textContaining('移除它的替换素材'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
  });

  testWidgets('没被钉的时候不出现这段说明——别拿噪音占地方', (tester) async {
    await pump(tester,
        locks: EditLocks.none, selection: EditorSelection.shot(0, 1));
    expect(find.textContaining('切分已锁定'), findsNothing);
  });

  testWidgets('单元里有钉住的镜头：拆分与合并整个单元都不给点', (tester) async {
    await pump(tester,
        locks: EditLocks(shots: {const ShotRef(0, 1)}),
        selection: EditorSelection.unit(0));
    expect(find.textContaining('S2'), findsWidgets, reason: '要点名是哪个镜头');
    expect(enabled(tester, 'inspector-split-btn'), isFalse, reason: '拆分应该是灰的');
    expect(enabled(tester, 'inspector-merge-btn'), isFalse, reason: '合并应该是灰的');
  });

  testWidgets('整体替换的单元：里面每个镜头都跟着锁', (tester) async {
    await pump(tester,
        locks: EditLocks(units: {0}), selection: EditorSelection.shot(0, 1));
    expect(enabled(tester, 'inspector-start-minus'), isFalse);
    expect(find.textContaining('已经不存在'), findsOneWidget,
        reason: '整段换掉之后原来的镜头在成片里确实没了，要说明白');
  });
}
