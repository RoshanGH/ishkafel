import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';

const _viewportWidth = 1200.0;
const _canvasHeight = 300.0;

/// 5 分钟素材：这正是固定桶数会失效的量级
const _durationMs = 300000;

List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: _durationMs,
        transcript: '整段台词',
        shots: [Shot(startMs: 0, endMs: _durationMs)],
      ),
    ];

/// 起伏明显的包络，便于按列统计"有没有画上柱子"
List<double> _envelope(int buckets) =>
    List.generate(buckets, (i) => 0.25 + 0.7 * (math.sin(i / 3.0).abs()));

Future<ByteData> _render(TimelineGeometry geometry, List<double> envelope) async {
  final painter = TimelinePainter(
    units: _units(),
    selection: null,
    geometry: geometry,
    waveEnvelope: envelope,
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

/// 波形轨里有多少个横向像素列被画上了内容
int _inkedColumns(ByteData bytes) => _columnTops(bytes).where((t) => t >= 0).length;

/// 每一列波形柱的顶端 y（无内容为 -1）
List<int> _columnTops(ByteData bytes) {
  final top = TimelineTracks.waveTop.round() + 1;
  final bottom = TimelineTracks.waveBottom.round() - 1;
  return List.generate(_viewportWidth.toInt(), (x) {
    for (var y = top; y < bottom; y++) {
      final o = (y * _viewportWidth.toInt() + x) * 4;
      if (bytes.getUint8(o + 3) > 0) return y;
    }
    return -1;
  });
}

/// 相邻列柱高发生变化的次数。
///
/// 这是区分「少数宽柱」与「密集细柱」的关键度量：只数"有墨的列"两者都能
/// 铺满视口，看不出差别；而一根宽柱内部所有列等高，高度变化次数直接反映
/// 波形的真实分辨率。
int _heightChanges(ByteData bytes) {
  final tops = _columnTops(bytes);
  var changes = 0;
  for (var i = 1; i < tops.length; i++) {
    if (tops[i] != tops[i - 1]) changes++;
  }
  return changes;
}

void main() {
  group('波形密度随缩放自适应（用户靠波形找语句停顿来定切点）', () {
    test('放大 20 倍后，波形仍然铺满视口而不是退化成十几根宽柱', () async {
      // 与 TimelineMediaBuilder.envelopeBucketsFor 一致：每秒 100 个样本
      final envelope = _envelope(30000);
      final fit = TimelineGeometry.fit(
          durationMs: _durationMs, viewportWidthPx: _viewportWidth);
      final zoomed =
          fit.zoomAt(_viewportWidth / 2, 20, viewportWidthPx: _viewportWidth);

      final bytes = await _render(zoomed, envelope);

      // 放大 20 倍后视口只覆盖 15 秒；2000 桶均摊到 300 秒 = 每桶 0.15s，
      // 视口内只有约 100 个桶。按桶画 → 100 根宽柱（约 100 次高度变化）；
      // 按可视像素重采样 → 数百次高度变化。
      expect(_heightChanges(bytes), greaterThan(300),
          reason: '放大后波形应按可视像素重采样，而不是把少数几个桶拉成宽柱——'
              '宽柱内部等高，用户完全看不出语句之间的停顿');
      expect(_inkedColumns(bytes), greaterThan(_viewportWidth * 0.5));
    });

    test('未放大时仍然正常铺满，不因重采样而变稀', () async {
      // 与 TimelineMediaBuilder.envelopeBucketsFor 一致：每秒 100 个样本
      final envelope = _envelope(30000);
      final fit = TimelineGeometry.fit(
          durationMs: _durationMs, viewportWidthPx: _viewportWidth);

      final columns = _inkedColumns(await _render(fit, envelope));
      expect(columns, greaterThan(_viewportWidth * 0.5));
    });

    test('包络样本比像素列还少时不崩、也不留空洞', () async {
      final fit = TimelineGeometry.fit(
          durationMs: _durationMs, viewportWidthPx: _viewportWidth);
      final columns = _inkedColumns(await _render(fit, _envelope(12)));

      expect(columns, greaterThan(_viewportWidth * 0.5),
          reason: '样本稀疏时应把每个样本铺满它覆盖的像素范围，而不是只点 12 列');
    });
  });
}
