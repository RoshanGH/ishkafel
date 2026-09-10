import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';

/// **光标要说得出「这儿能干什么」。**
///
/// 2026-09-09 设计走查：时间线上鼠标压在边界手柄上，光标还是普通箭头——
/// 人得靠试才知道哪儿能拖。专业剪辑工具在这儿一律是双向箭头。
void main() {
  SegmentationEditorController controller() {
    final c = SegmentationEditorController(
      initialUnits: const [
        SemanticUnit(
            uid: 'u0',
            index: 0,
            startMs: 0,
            endMs: 8000,
            transcript: 'U1',
            shots: [Shot(startMs: 0, endMs: 4000), Shot(startMs: 4000, endMs: 8000)]),
        SemanticUnit(
            uid: 'u1',
            index: 1,
            startMs: 8000,
            endMs: 16000,
            transcript: 'U2',
            shots: [Shot(startMs: 8000, endMs: 16000)]),
      ],
      durationMs: 16000,
      fps: 30,
      sentences: const [],
    );
    return c;
  }

  Future<MouseCursor> cursorAt(WidgetTester tester, Offset local) async {
    final c = controller();
    final geometry = TimelineGeometry.fit(durationMs: 16000, viewportWidthPx: 800);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: TimelineTracks.totalHeight,
          child: TimelineView(
            controller: c,
            geometry: geometry,
            playhead: ValueNotifier<int>(0),
            onSeek: (_) {},
            onGeometryChanged: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final origin = tester.getTopLeft(find.byType(TimelineView));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(origin + local);
    await tester.pumpAndSettle();

    return tester
        .widgetList<MouseRegion>(find.descendant(
            of: find.byType(TimelineView), matching: find.byType(MouseRegion)))
        .map((m) => m.cursor)
        .firstWhere((c) => c != MouseCursor.defer,
            orElse: () => MouseCursor.defer);
  }

  testWidgets('压在单元边界上：双向箭头', (tester) async {
    // U1 / U2 的交界在 8000ms，800px 铺 16000ms → x = 400
    final cursor = await cursorAt(
        tester, Offset(400, TimelineTracks.unitsTop + 10));

    expect(cursor, SystemMouseCursors.resizeLeftRight,
        reason: '边界能拖着改切分，光标得说出来');
  });

  testWidgets('压在刻度尺上：可以拖播放头', (tester) async {
    final cursor = await cursorAt(tester, const Offset(300, 8));

    expect(cursor, SystemMouseCursors.resizeColumn);
  });

  testWidgets('压在块体中间：普通箭头，别乱暗示', (tester) async {
    final cursor = await cursorAt(
        tester, Offset(120, TimelineTracks.unitsTop + 10));

    expect(cursor, MouseCursor.defer,
        reason: '块体中间只能点选，给个拖拽光标是在骗人');
  });
}
