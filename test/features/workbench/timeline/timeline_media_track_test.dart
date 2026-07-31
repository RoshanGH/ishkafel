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
const _canvasHeight = 300.0;
const _durationMs = 40000;

List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: _durationMs,
        transcript: '整段台词',
        shots: [Shot(startMs: 0, endMs: _durationMs)],
      ),
    ];

Future<ByteData> _render(TimelineMediaStatus status) async {
  final painter = TimelinePainter(
    units: _units(),
    selection: null,
    geometry: TimelineGeometry.fit(
        durationMs: _durationMs, viewportWidthPx: _viewportWidth),
    playheadMs: 0,
    mediaStatus: status,
  );
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), const Size(_viewportWidth, _canvasHeight));
  final image = await recorder
      .endRecording()
      .toImage(_viewportWidth.toInt(), _canvasHeight.toInt());
  addTearDown(image.dispose);
  return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
}

int _regionInk(ByteData bytes, double top, double bottom) {
  var ink = 0;
  for (var y = top.round() + 1; y < bottom.round() - 1; y++) {
    for (var x = 10; x < 1500; x += 3) {
      final o = (y * _viewportWidth.toInt() + x) * 4;
      if (bytes.getUint8(o + 3) > 0) ink++;
    }
  }
  return ink;
}

void main() {
  group('抽帧轨与波形轨的加载/失败反馈（静默空白会被误认为坏了）', () {
    test('加载中：两条轨画出占位，而不是一片空白', () async {
      final bytes = await _render(TimelineMediaStatus.loading);

      expect(
          _regionInk(
              bytes, TimelineTracks.thumbsTop, TimelineTracks.thumbsBottom),
          greaterThan(0),
          reason: '抽帧要跑十几次 ffmpeg，期间整条轨全空白，用户会以为这栏坏了');
      expect(
          _regionInk(bytes, TimelineTracks.waveTop, TimelineTracks.waveBottom),
          greaterThan(0),
          reason: '波形轨同理');
    });

    test('失败：颜色与加载中可分辨（失败用红色系）', () async {
      final loading = await _render(TimelineMediaStatus.loading);
      final failed = await _render(TimelineMediaStatus.failed);

      // 取轨道内一点，比色相而不是比"有没有像素"——两种状态都会铺满轨道，
      // 像素数量相同，真正区分它们的是颜色
      final y = ((TimelineTracks.thumbsTop + TimelineTracks.thumbsBottom) / 2)
          .round();
      const x = 800;
      ({int r, int g, int b}) at(ByteData bytes) {
        final o = (y * _viewportWidth.toInt() + x) * 4;
        return (
          r: bytes.getUint8(o),
          g: bytes.getUint8(o + 1),
          b: bytes.getUint8(o + 2),
        );
      }

      final l = at(loading);
      final f = at(failed);
      expect(f, isNot(l),
          reason: '「在算」和「算失败了」必须能被用户区分，否则失败等于静默');
      expect(f.r, greaterThan(f.g),
          reason: '失败态应偏红（AppColors.red），与中性的加载态区分开');
    });

    test('就绪态不画占位，把轨道让给真实内容', () async {
      final bytes = await _render(TimelineMediaStatus.ready);
      expect(
          _regionInk(
              bytes, TimelineTracks.thumbsTop, TimelineTracks.thumbsBottom),
          0,
          reason: '数据已就绪却仍盖着占位层，会把真实抽帧盖住');
    });
  });
}
