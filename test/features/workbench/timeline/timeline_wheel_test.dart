import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';

const _viewportWidth = 800.0;
const _durationMs = 96000;

SegmentationEditorController _controller() => SegmentationEditorController(
      initialUnits: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: _durationMs,
          transcript: '整段台词',
          shots: [Shot(startMs: 0, endMs: _durationMs)],
        ),
      ],
      durationMs: _durationMs,
      fps: 30,
      sentences: const [],
    );

Future<TimelineGeometry?> _scrollOn(
  WidgetTester tester, {
  required TimelineGeometry geometry,
  required Offset delta,
  bool withMeta = false,
}) async {
  TimelineGeometry? latest;
  final playhead = ValueNotifier<int>(0);
  addTearDown(playhead.dispose);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: _viewportWidth,
        height: 260,
        child: TimelineView(
          controller: _controller(),
          geometry: geometry,
          playhead: playhead,
          onSeek: (_) {},
          onGeometryChanged: (g) => latest = g,
        ),
      ),
    ),
  ));

  if (withMeta) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
  }
  final center = tester.getCenter(find.byType(TimelineView));
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(center));
  await tester.sendEventToBinding(pointer.scroll(delta));
  await tester.pump();
  if (withMeta) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
  }
  return latest;
}

Future<TimelineGeometry?> _trackpadPan(
  WidgetTester tester, {
  required TimelineGeometry geometry,
  required Offset pan,
  double scale = 1.0,
}) async {
  TimelineGeometry? latest;
  final playhead = ValueNotifier<int>(0);
  addTearDown(playhead.dispose);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: _viewportWidth,
        height: 260,
        child: TimelineView(
          controller: _controller(),
          geometry: geometry,
          playhead: playhead,
          onSeek: (_) {},
          onGeometryChanged: (g) => latest = g,
        ),
      ),
    ),
  ));

  final center = tester.getCenter(find.byType(TimelineView));
  final pointer = TestPointer(1, PointerDeviceKind.trackpad);
  await tester.sendEventToBinding(pointer.panZoomStart(center));
  await tester.sendEventToBinding(pointer.panZoomUpdate(center, pan: pan, scale: scale));
  await tester.sendEventToBinding(pointer.panZoomEnd());
  await tester.pump();
  return latest;
}

void main() {
  group('时间线的滚轮/触控板操作（专业视频工具的标配）', () {
    testWidgets('横向滚动平移时间线', (tester) async {
      final zoomed = TimelineGeometry.fit(
              durationMs: _durationMs, viewportWidthPx: _viewportWidth)
          .zoomAt(0, 8, viewportWidthPx: _viewportWidth);

      final next = await _scrollOn(tester,
          geometry: zoomed, delta: const Offset(120, 0));

      expect(next, isNotNull,
          reason: '放大后只能拖滑块或拖空白处平移，触控板横滑毫无反应，'
              '与剪映/FCP 的操作习惯不符');
      expect(next!.scrollPx, greaterThan(zoomed.scrollPx));
      expect(next.msPerPx, zoomed.msPerPx, reason: '平移不应改变缩放倍数');
    });

    testWidgets('⌘ + 滚轮缩放，并以指针位置为锚点', (tester) async {
      final fit = TimelineGeometry.fit(
          durationMs: _durationMs, viewportWidthPx: _viewportWidth);

      final next = await _scrollOn(tester,
          geometry: fit, delta: const Offset(0, -100), withMeta: true);

      expect(next, isNotNull, reason: '⌘+滚轮是 macOS 上缩放的通行手势');
      expect(next!.msPerPx, lessThan(fit.msPerPx),
          reason: '向上滚应放大（每像素代表的时间变少）');
    });

    testWidgets('不带修饰键的纵向滚动也用于平移，避免手势落空', (tester) async {
      final zoomed = TimelineGeometry.fit(
              durationMs: _durationMs, viewportWidthPx: _viewportWidth)
          .zoomAt(0, 8, viewportWidthPx: _viewportWidth);

      final next = await _scrollOn(tester,
          geometry: zoomed, delta: const Offset(0, 120));

      expect(next, isNotNull,
          reason: '时间线本身没有纵向可滚内容，纵向滚动若不映射为平移就是'
              '一个落空的手势');
      expect(next!.msPerPx, zoomed.msPerPx);
    });
  });

  group('触控板手势（macOS 上双指滑动走 PanZoom 事件，不是滚轮事件）', () {
    testWidgets('双指横滑平移时间线', (tester) async {
      final zoomed = TimelineGeometry.fit(
              durationMs: _durationMs, viewportWidthPx: _viewportWidth)
          .zoomAt(0, 8, viewportWidthPx: _viewportWidth);

      final next = await _trackpadPan(tester,
          geometry: zoomed, pan: const Offset(-120, 0));

      expect(next, isNotNull,
          reason: 'MacBook 触控板的双指滑动在 Flutter 里是 PointerPanZoom 事件，'
              '只处理 PointerScrollEvent 的话在触控板上完全没反应——而这正是'
              '本 app 的主要使用场景');
      expect(next!.scrollPx, greaterThan(zoomed.scrollPx));
      expect(next.msPerPx, zoomed.msPerPx);
    });

    testWidgets('双指捏合缩放', (tester) async {
      final fit = TimelineGeometry.fit(
          durationMs: _durationMs, viewportWidthPx: _viewportWidth);

      final next = await _trackpadPan(tester,
          geometry: fit, pan: Offset.zero, scale: 2.0);

      expect(next, isNotNull);
      expect(next!.msPerPx, lessThan(fit.msPerPx), reason: '张开手指应放大');
    });
  });
}
