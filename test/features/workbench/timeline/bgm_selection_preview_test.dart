import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/text_layout_cache.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';

/// U1 = 0~6000（三个镜头），U2 = 6000~10000（一个镜头）
SegmentationEditorController _editor() => SegmentationEditorController(
      sentences: const [],
      initialUnits: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 6000,
          transcript: 'U1',
          shots: [
            Shot(startMs: 0, endMs: 2000),
            Shot(startMs: 2000, endMs: 4000),
            Shot(startMs: 4000, endMs: 6000),
          ],
        ),
        SemanticUnit(
          index: 1,
          startMs: 6000,
          endMs: 10000,
          transcript: 'U2',
          shots: [Shot(startMs: 6000, endMs: 10000)],
        ),
      ],
      durationMs: 10000,
      fps: 30,
    );

/// 记下画过的矩形，用来验框选预览到底铺了多宽。
/// implements 而不是 extends——Canvas 不能被继承
class _RectRecorder implements Canvas {
  final rects = <Rect>[];

  @override
  void drawRect(Rect rect, Paint paint) => rects.add(rect);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test('框选一个台词语义单元时，预览铺满整个单元而不是它的第一个镜头', () {
    final editor = _editor();
    final geometry = TimelineGeometry.fit(durationMs: 10000, viewportWidthPx: 500);
    final canvas = _RectRecorder();

    TimelinePainter(
      units: editor.units,
      selection: null,
      geometry: geometry,
      bgm: BgmPlan.empty,
      // 框选 U1（下标 0）
      bgmSelecting: (from: 0, to: 0),
      textCache: TextLayoutCache(),
      playheadMs: 0,
    ).paint(canvas, const Size(500, 400));

    // 配乐轨上第一个矩形是轨道底色，第二个才是框选预览
    final top = TimelineTracks.bgmTop;
    final onTrack =
        canvas.rects.where((r) => (r.top - top).abs() < 0.5).toList();
    final preview = onTrack[1];

    expect(preview.right, closeTo(300, 1),
        reason: 'U1 是 0~6000ms，500px 对应 10000ms，所以该铺到 x=300。'
            '此前拿单元下标去查打平后的镜头，只画出 S1 那 100px——'
            '看着就是「拉不动」');
  });

  test('框选两个单元时铺满两个', () {
    final editor = _editor();
    final geometry = TimelineGeometry.fit(durationMs: 10000, viewportWidthPx: 500);
    final canvas = _RectRecorder();

    TimelinePainter(
      units: editor.units,
      selection: null,
      geometry: geometry,
      bgmSelecting: (from: 0, to: 1),
      textCache: TextLayoutCache(),
      playheadMs: 0,
    ).paint(canvas, const Size(500, 400));

    final top = TimelineTracks.bgmTop;
    final onTrack =
        canvas.rects.where((r) => (r.top - top).abs() < 0.5).toList();

    expect(onTrack[1].right, closeTo(500, 1));
  });
}
