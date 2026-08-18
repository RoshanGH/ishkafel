import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';

/// fixture：2 个单元，各 2 个镜头，总时长 4000ms，fps=30
/// unit0: [0,2000)ms，shots: [0,1000)/[1000,2000)
/// unit1: [2000,4000)ms，shots: [2000,3000)/[3000,4000)
List<SemanticUnit> _fixtureUnits() => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '第一句台词内容示例',
        shots: [
          Shot(startMs: 0, endMs: 1000),
          Shot(startMs: 1000, endMs: 2000),
        ],
      ),
      SemanticUnit(
        index: 1,
        startMs: 2000,
        endMs: 4000,
        transcript: '第二句台词内容示例',
        shots: [
          Shot(startMs: 2000, endMs: 3000),
          Shot(startMs: 3000, endMs: 4000),
        ],
      ),
    ];

SegmentationEditorController _makeController() => SegmentationEditorController(
      initialUnits: _fixtureUnits(),
      durationMs: 4000,
      fps: 30,
      sentences: const [],
    );

/// 800x400 视口 fit geometry：msPerPx=5，unit 边界（2000ms）落在 x=400px
Widget _wrap({
  required SegmentationEditorController controller,
  required TimelineGeometry geometry,
  required ValueChanged<int> onSeek,
  required ValueChanged<TimelineGeometry> onGeometryChanged,
  bool readOnly = false,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 180,
          child: TimelineView(
            controller: controller,
            geometry: geometry,
            playhead: ValueNotifier<int>(0),
            onSeek: onSeek,
            onGeometryChanged: onGeometryChanged,
            readOnly: readOnly,
          ),
        ),
      ),
    );

void main() {
  testWidgets('①点击单元块中心 → controller.selection 变为该单元', (tester) async {
    final controller = _makeController();
    final geometry = TimelineGeometry.fit(durationMs: 4000, viewportWidthPx: 800);
    await tester.pumpWidget(_wrap(
      controller: controller,
      geometry: geometry,
      onSeek: (_) {},
      onGeometryChanged: (_) {},
    ));

    // unit0: ms[0,2000) → px[0,400)，中心 x=200；单元轨 y 取中值 46
    await tester.tapAt(const Offset(200, 46));
    await tester.pump();

    expect(controller.selection?.unitIndex, 0);
    expect(controller.selection?.shotIndex, isNull);
  });

  testWidgets('②点击刻度区 → onSeek 收到对应 ms（±1 帧容差）', (tester) async {
    final controller = _makeController();
    final geometry = TimelineGeometry.fit(durationMs: 4000, viewportWidthPx: 800);
    int? seekedMs;
    await tester.pumpWidget(_wrap(
      controller: controller,
      geometry: geometry,
      onSeek: (ms) => seekedMs = ms,
      onGeometryChanged: (_) {},
    ));

    // 刻度轨 y in [0,20)；x=100px → 500ms
    await tester.tapAt(const Offset(100, 10));
    await tester.pump();

    expect(seekedMs, isNotNull);
    final frameMs = (1000 / 30).round();
    expect((seekedMs! - 500).abs() <= frameMs, isTrue,
        reason: '实际 seekedMs=$seekedMs');
  });

  testWidgets('③边界拖不动（产品决定 2026-08-18）：在单元交界处拖拽只滚动，不改边界', (tester) async {
    // 切分边界来自分析管线 + 帧信号，人要做的是「切、合并、逐帧微调」——
    // 在轴上把两段拉来拉去的自由度只带来误操作，已整体移除
    final controller = _makeController();
    final geometry = TimelineGeometry.fit(durationMs: 4000, viewportWidthPx: 800);
    await tester.pumpWidget(_wrap(
      controller: controller,
      geometry: geometry,
      onSeek: (_) {},
      onGeometryChanged: (_) {},
    ));

    // unit0/unit1 边界在 x=400px（2000ms），在单元轨上拖拽
    await tester.dragFrom(const Offset(400, 46), const Offset(40, 0));
    await tester.pump();

    expect(controller.units[0].endMs, 2000, reason: '边界一动不动');
    expect(controller.units[1].startMs, 2000);
    expect(controller.canUndo, isFalse, reason: '没有编辑发生，不产生撤销记录');
    expect(controller.inDragSession, isFalse, reason: '不再开启拖拽会话');
  });

  testWidgets('④在空白块体处拖拽 → onGeometryChanged 收到滚动后的 geometry（zoom 后可滚状态）',
      (tester) async {
    final controller = _makeController();
    // 先放大 2 倍使总宽度(1600px) > 视口(800px)，才有可滚动空间
    final zoomed = TimelineGeometry.fit(durationMs: 4000, viewportWidthPx: 800)
        .zoomAt(400, 2.0, viewportWidthPx: 800);
    TimelineGeometry? received;
    await tester.pumpWidget(_wrap(
      controller: controller,
      geometry: zoomed,
      onSeek: (_) {},
      onGeometryChanged: (g) => received = g,
    ));

    // 在单元轨块体内部（远离边界手柄）拖拽
    await tester.dragFrom(const Offset(100, 46), const Offset(-150, 0));
    await tester.pump();

    expect(received, isNotNull);
    expect(received!.scrollPx, isNot(zoomed.scrollPx));
  });

  testWidgets('⑤双击镜头块 → selection 为镜头层', (tester) async {
    final controller = _makeController();
    final geometry = TimelineGeometry.fit(durationMs: 4000, viewportWidthPx: 800);
    await tester.pumpWidget(_wrap(
      controller: controller,
      geometry: geometry,
      onSeek: (_) {},
      onGeometryChanged: (_) {},
    ));

    // unit0 内 shot0：ms[0,1000) → px[0,200)；镜头轨 y 取中值 85
    // 从轨道常量推导，避免布局调整（如加轨道标题条）时坐标失效
    final shotPos = Offset(
        100, (TimelineTracks.shotsTop + TimelineTracks.shotsBottom) / 2);
    await tester.tapAt(shotPos);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(shotPos);
    await tester.pump();

    expect(controller.selection?.unitIndex, 0);
    expect(controller.selection?.shotIndex, 0);
  });

  testWidgets('⑤b 双击镜头块过程中不应出现中间的单元选中', (tester) async {
    final controller = _makeController();
    final geometry = TimelineGeometry.fit(durationMs: 4000, viewportWidthPx: 800);
    final selectionLog = <EditorSelection?>[];
    controller.addListener(() => selectionLog.add(controller.selection));
    await tester.pumpWidget(_wrap(
      controller: controller,
      geometry: geometry,
      onSeek: (_) {},
      onGeometryChanged: (_) {},
    ));

    // 从轨道常量推导，避免布局调整（如加轨道标题条）时坐标失效
    final shotPos = Offset(
        100, (TimelineTracks.shotsTop + TimelineTracks.shotsBottom) / 2);
    await tester.tapAt(shotPos);
    await tester.pump(const Duration(milliseconds: 80)); // 双击窗口内，未超时
    await tester.tapAt(shotPos);
    // 冲掉可能残留的挂起定时器（若有），避免测试框架的 pending timer 检查报错
    await tester.pump(const Duration(milliseconds: 350));

    expect(controller.selection?.unitIndex, 0);
    expect(controller.selection?.shotIndex, 0);
    expect(
      selectionLog.any((s) => s != null && s.shotIndex == null),
      isFalse,
      reason: '双击过程中不应出现中间的单元层选中（selectionLog=$selectionLog）',
    );
  });

  group('readOnly（评审 Important 1：回看模式不可编辑）', () {
    testWidgets('readOnly 时拖拽单元交界处不改变 units', (tester) async {
      final controller = _makeController();
      final geometry = TimelineGeometry.fit(durationMs: 4000, viewportWidthPx: 800);
      await tester.pumpWidget(_wrap(
        controller: controller,
        geometry: geometry,
        onSeek: (_) {},
        onGeometryChanged: (_) {},
        readOnly: true,
      ));

      await tester.dragFrom(const Offset(400, 46), const Offset(40, 0));
      await tester.pump();

      expect(controller.units[0].endMs, 2000);
      expect(controller.units[1].startMs, 2000);
      expect(controller.canUndo, isFalse);
    });

    testWidgets('readOnly 时点选单元块仍可用', (tester) async {
      final controller = _makeController();
      final geometry = TimelineGeometry.fit(durationMs: 4000, viewportWidthPx: 800);
      await tester.pumpWidget(_wrap(
        controller: controller,
        geometry: geometry,
        onSeek: (_) {},
        onGeometryChanged: (_) {},
        readOnly: true,
      ));

      await tester.tapAt(const Offset(200, 46));
      await tester.pump();

      expect(controller.selection?.unitIndex, 0);
    });

    testWidgets('readOnly 时点击刻度区仍可 seek', (tester) async {
      final controller = _makeController();
      final geometry = TimelineGeometry.fit(durationMs: 4000, viewportWidthPx: 800);
      int? seekedMs;
      await tester.pumpWidget(_wrap(
        controller: controller,
        geometry: geometry,
        onSeek: (ms) => seekedMs = ms,
        onGeometryChanged: (_) {},
        readOnly: true,
      ));

      await tester.tapAt(const Offset(100, 10));
      await tester.pump();

      expect(seekedMs, isNotNull);
    });

    testWidgets('readOnly 时空白处水平拖拽仍可滚动', (tester) async {
      final controller = _makeController();
      final zoomed = TimelineGeometry.fit(durationMs: 4000, viewportWidthPx: 800)
          .zoomAt(400, 2.0, viewportWidthPx: 800);
      TimelineGeometry? received;
      await tester.pumpWidget(_wrap(
        controller: controller,
        geometry: zoomed,
        onSeek: (_) {},
        onGeometryChanged: (g) => received = g,
        readOnly: true,
      ));

      await tester.dragFrom(const Offset(100, 46), const Offset(-150, 0));
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.scrollPx, isNot(zoomed.scrollPx));
    });
  });
}
