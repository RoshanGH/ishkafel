import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';

const _viewportWidth = 1600.0;
const _canvasHeight = 220.0;
const _durationMs = 40000;

/// 单元内三个视觉镜头，块宽分别 400/600/600px，足够画出块体与编号
List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: _durationMs,
        transcript: '整段台词',
        shots: [
          Shot(startMs: 0, endMs: 10000),
          Shot(startMs: 10000, endMs: 25000),
          Shot(startMs: 25000, endMs: _durationMs),
        ],
      ),
    ];

TimelinePainter _painter({EditorSelection? selection}) => TimelinePainter(
      units: _units(),
      selection: selection,
      geometry: TimelineGeometry.fit(
          durationMs: _durationMs, viewportWidthPx: _viewportWidth),
      playheadMs: 0,
    );

Future<ByteData> _render(TimelinePainter painter) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), const Size(_viewportWidth, _canvasHeight));
  final image = await recorder
      .endRecording()
      .toImage(_viewportWidth.toInt(), _canvasHeight.toInt());
  addTearDown(image.dispose);
  return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
}

({int a, int r, int g, int b}) _pixel(ByteData bytes, int x, int y) {
  final o = (y * _viewportWidth.toInt() + x) * 4;
  return (
    a: bytes.getUint8(o + 3),
    r: bytes.getUint8(o),
    g: bytes.getUint8(o + 1),
    b: bytes.getUint8(o + 2),
  );
}

/// 镜头轨垂直中心
int get _shotsCenterY =>
    ((TimelineTracks.shotsTop + TimelineTracks.shotsBottom) / 2).round();

void main() {
  group('视觉镜头轨可见性（产品核心是两层切分，镜头层必须看得见才能编辑）', () {
    test('每个镜头都画出可见块体，而不是只有一根分隔线', () async {
      final bytes = await _render(_painter());

      // 三个镜头块体的水平中心：200 / 700 / 1300
      for (final x in [200, 700, 1300]) {
        final px = _pixel(bytes, x, _shotsCenterY);
        expect(px.a, greaterThan(0),
            reason: 'x=$x 处的镜头块体没有任何填充，用户在时间线上看不见这个镜头');
      }
    });

    test('选中的镜头以紫色高亮，与未选中的镜头在视觉上可区分', () async {
      final selected = await _render(
          _painter(selection: const EditorSelection.shot(0, 1)));
      final normal = await _render(_painter());

      const x = 700; // 第二个镜头（被选中）的中心
      final sel = _pixel(selected, x, _shotsCenterY);
      final unsel = _pixel(normal, x, _shotsCenterY);

      expect(sel.a, greaterThan(unsel.a),
          reason: '选中态应比未选中态更实，否则用户看不出选了哪个镜头');
      expect(sel.b, greaterThan(sel.g),
          reason: '选中态应为紫色系（AppColors.purple 蓝通道高于绿通道）');
    });

    test('相邻镜头之间有比块体本身更实的分界，不会连成一整块', () async {
      final bytes = await _render(_painter());

      // 10000ms 处是第一、二个镜头的交界，落在 x=400
      final boundary = _pixel(bytes, 400, _shotsCenterY);
      final interior = _pixel(bytes, 200, _shotsCenterY);
      expect(boundary.a, greaterThan(interior.a),
          reason: '交界处应有描边/间隙形成的分界，否则整条轨看起来是一整块；'
              '本用例与「块体有填充」一起才构成"块体清晰可数"的完整断言');
    });

    test('亚像素宽的镜头块体不让 paint 抛异常（同族回归）', () {
      const units = [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: _durationMs,
          transcript: '整段台词',
          shots: [
            Shot(startMs: 0, endMs: _durationMs - 20),
            Shot(startMs: _durationMs - 20, endMs: _durationMs),
          ],
        ),
      ];
      final painter = TimelinePainter(
        units: units,
        selection: null,
        geometry: TimelineGeometry.fit(
            durationMs: _durationMs, viewportWidthPx: _viewportWidth),
        playheadMs: 0,
      );

      expect(
        () => painter.paint(
            Canvas(ui.PictureRecorder()), const Size(_viewportWidth, _canvasHeight)),
        returnsNormally,
      );
    });
  });
}
