import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';

const _viewportWidth = 1600.0;
const _canvasHeight = 220.0;
const _durationMs = 40000;

List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: _durationMs,
        transcript: '再不买就恢复六十九块九一瓶了，如果你觉得有点贵那就趁现在赶紧买',
        shots: [Shot(startMs: 0, endMs: _durationMs)],
      ),
    ];

Future<ByteData> _render() async {
  final painter = TimelinePainter(
    units: _units(),
    selection: null,
    geometry: TimelineGeometry.fit(
        durationMs: _durationMs, viewportWidthPx: _viewportWidth),
    playheadMs: 0,
  );
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), const Size(_viewportWidth, _canvasHeight));
  final image = await recorder
      .endRecording()
      .toImage(_viewportWidth.toInt(), _canvasHeight.toInt());
  addTearDown(image.dispose);
  return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
}

/// 该行在给定横向范围内的最大亮度（用于判断这一行有没有文字落上去）
int _rowPeakLuma(ByteData bytes, int y, {int fromX = 20, int toX = 900}) {
  var peak = 0;
  for (var x = fromX; x < toX; x++) {
    final o = (y * _viewportWidth.toInt() + x) * 4;
    final luma =
        bytes.getUint8(o) + bytes.getUint8(o + 1) + bytes.getUint8(o + 2);
    if (luma > peak) peak = luma;
  }
  return peak;
}

void main() {
  group('台词语义单元块体信息层级', () {
    test('块体内有上下两行文字，而不是把编号和台词挤成一行', () async {
      final bytes = await _render();

      final top = TimelineTracks.unitsTop.round();
      final bottom = TimelineTracks.unitsBottom.round();
      final mid = (top + bottom) ~/ 2;

      // 填充本身是均匀的，只有文字会把某些行的峰值亮度顶上去；
      // 以块体最暗行为基线，显著高于基线的行判定为「有文字」
      var baseline = 1 << 30;
      for (var y = top + 1; y < bottom - 1; y++) {
        final p = _rowPeakLuma(bytes, y);
        if (p < baseline) baseline = p;
      }

      bool hasTextIn(int fromY, int toY) {
        for (var y = fromY; y < toY; y++) {
          if (_rowPeakLuma(bytes, y) > baseline + 120) return true;
        }
        return false;
      }

      expect(hasTextIn(top + 1, mid), isTrue,
          reason: '块体上半部应有第一行（单元编号与时长），便于扫读定位');
      expect(hasTextIn(mid, bottom - 1), isTrue,
          reason: '块体下半部应有第二行（台词摘要）；只画一行时下半部只有纯填充');
    });
  });
}
