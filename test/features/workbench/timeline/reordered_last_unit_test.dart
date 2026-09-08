import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/text_layout_cache.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';

/// **列表顺序和原片顺序不一致时，最后那一格不许消失。**
///
/// 2026-09-08 真机：手加的单元被拖到最前面，它在原片上的占位是
/// `[96233, 106233)`；而原片里最后一个单元的 `endMs` 正好是 96233。
/// 画单元块时用的是「原片毫秒 → 成片毫秒」，那个换算按「谁的原片区间盖住它」
/// 找——`endMs` 是开区间，落进的是**手加单元**，于是右边界被算成了它的成片
/// 起点 0。矩形左右翻转，那一格什么都画不出来：镜头轨上还有 S1，
/// 单元轨那里是空的。
///
/// 根治办法是**别再拿原片时间去换算**：单元和镜头在成片里的位置，
/// 按列表下标直接问成片轴就有，精确且与顺序无关。
void main() {
  const viewportWidth = 1600.0;
  final canvasHeight = TimelineTracks.totalHeight + 10;

  /// U1 手加（原片占位排在末尾），拖到了列表最前；U2/U3 来自原片
  List<SemanticUnit> units() => const [
        SemanticUnit(
            index: 0,
            startMs: 20000,
            endMs: 30000,
            transcript: '',
            hasSource: false),
        SemanticUnit(
            index: 1,
            startMs: 0,
            endMs: 10000,
            transcript: '第一句',
            shots: [Shot(startMs: 0, endMs: 10000)]),
        SemanticUnit(
            index: 2,
            startMs: 10000,
            endMs: 20000,
            transcript: '第二句',
            shots: [Shot(startMs: 10000, endMs: 20000)]),
      ];

  Future<ByteData> render() async {
    final axis =
        ComposedTimeline.of(units: units(), wholeDurations: const {});
    final painter = TimelinePainter(
      units: units(),
      selection: null,
      geometry: TimelineGeometry.fit(
          durationMs: axis.totalMs,
          viewportWidthPx: viewportWidth,
          axis: axis),
      playheadMs: 0,
      textCache: TextLayoutCache(),
    );
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), Size(viewportWidth, canvasHeight));
    final image = await recorder
        .endRecording()
        .toImage(viewportWidth.toInt(), canvasHeight.toInt());
    addTearDown(image.dispose);
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  }

  int alpha(ByteData bytes, int x, int y) =>
      bytes.getUint8((y * viewportWidth.toInt() + x) * 4 + 3);

  int luma(ByteData bytes, int x, int y) {
    final o = (y * viewportWidth.toInt() + x) * 4;
    return bytes.getUint8(o) + bytes.getUint8(o + 1) + bytes.getUint8(o + 2);
  }

  test('原片里最后那个单元照样画出块体', () async {
    final bytes = await render();
    // 成片总长 30s，视口 1600px：U3 在成片 20s~30s，即 x 1066~1600
    final y = (TimelineTracks.unitsTop + TimelineTracks.unitsBottom) ~/ 2;

    expect(luma(bytes, 1300, y), greaterThan(0),
        reason: '真机上这里是全黑：U3 的右边界被算到了手加单元的成片起点 0，'
            '矩形左右翻转，整格画不出来');
    expect(alpha(bytes, 1300, y), greaterThan(0));
  });

  test('前面几格照旧', () async {
    final bytes = await render();
    final y = (TimelineTracks.unitsTop + TimelineTracks.unitsBottom) ~/ 2;

    // U1 在成片 0~10s（x 0~533），U2 在 10~20s（x 533~1066）
    expect(luma(bytes, 200, y), greaterThan(0));
    expect(luma(bytes, 800, y), greaterThan(0));
  });

  test('镜头轨上最后一镜也在', () async {
    final bytes = await render();
    final y = (TimelineTracks.shotsTop + TimelineTracks.shotsBottom) ~/ 2;

    expect(luma(bytes, 1300, y), greaterThan(0),
        reason: '同一个换算，最后一镜的 endMs 等于所属单元的 endMs，一样会翻转');
  });
}
