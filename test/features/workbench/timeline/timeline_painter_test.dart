import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/app/theme/app_colors.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/text_layout_cache.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';

/// 时间线视口宽（与真机审片台一致的量级，保证极窄单元真的窄到亚像素）
const _viewportWidth = 1600.0;

/// 画布高度取到波形轨以下，留出一段只有播放头会经过的空白区域用于像素取样
/// 画布要够高，把所有轨都画进来——写死数字的话，每加一条轨这些测试都会
/// 莫名其妙地挂（2026-09-08 加字幕轨时就撞了一次）
final _canvasHeight = TimelineTracks.totalHeight + 10;

/// 真机复现数据的等价缩影：末单元只有 53ms，在 1600px 视口下宽约 0.92px，
/// 「块宽 - 左右内边距」为负数 —— 这正是让整帧绘制中断的输入。
List<SemanticUnit> _unitsWithSliverTail() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 46000,
        transcript: '前半段台词，块体足够宽',
        shots: [Shot(startMs: 0, endMs: 46000)],
      ),
      SemanticUnit(
        index: 1,
        startMs: 46000,
        endMs: 92200,
        transcript: '后半段台词，块体足够宽',
        shots: [Shot(startMs: 46000, endMs: 92200)],
      ),
      SemanticUnit(
        index: 2,
        startMs: 92200,
        endMs: 92253,
        transcript: '极窄末单元',
        shots: [Shot(startMs: 92200, endMs: 92253)],
      ),
    ];

TimelinePainter _painter({required int playheadMs}) {
  final units = _unitsWithSliverTail();
  return TimelinePainter(
    units: units,
    selection: null,
    geometry: TimelineGeometry.fit(
        durationMs: 92253, viewportWidthPx: _viewportWidth),
    playheadMs: playheadMs,
  
    textCache: TextLayoutCache(),);
}

Future<ui.Image> _paintToImage(TimelinePainter painter) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, Size(_viewportWidth, _canvasHeight));
  final picture = recorder.endRecording();
  return picture.toImage(_viewportWidth.toInt(), _canvasHeight.toInt());
}

void main() {
  group('TimelinePainter 极窄单元块体', () {
    test('①亚像素宽的单元块体不应让 paint 抛异常', () {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      // 回归防线：块宽小于文字内边距时，若把负数 maxWidth 交给 TextPainter.layout，
      // 会在 clampDouble(min:0, max:负数) 处抛 AssertionError；该异常发生在 paint()
      // 中途，会让本帧后续所有绘制（镜头/抽帧/波形轨、顶栏、底栏）全部丢失。
      expect(
        () => _painter(playheadMs: 46000)
            .paint(canvas, Size(_viewportWidth, _canvasHeight)),
        returnsNormally,
      );
    });

    test('②极窄单元之后的绘制（播放头）仍然落到画布上', () async {
      const playheadMs = 46000;
      final painter = _painter(playheadMs: playheadMs);
      final image = await _paintToImage(painter);
      final bytes =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      addTearDown(image.dispose);

      final playheadX = painter.geometry.msToPx(playheadMs).round();
      // 取样点落在所有轨道下方的空白区域，只有最后绘制的播放头会经过；
      // 线宽 2px 且落在半像素上会被抗锯齿摊到相邻列，故取左右各 2px 的最亮点
      const sampleY = 210;
      var best = (a: 0, r: 0, g: 0, b: 0);
      for (var x = playheadX - 2; x <= playheadX + 2; x++) {
        final offset = (sampleY * _viewportWidth.toInt() + x) * 4;
        final alpha = bytes!.getUint8(offset + 3);
        if (alpha <= best.a) continue;
        best = (
          a: alpha,
          r: bytes.getUint8(offset),
          g: bytes.getUint8(offset + 1),
          b: bytes.getUint8(offset + 2),
        );
      }

      expect(best.a, greaterThan(0),
          reason: '播放头是 paint 的最后一步，画不出来说明绘制在中途被打断了');
      // rawRgba 为预乘 alpha，只校验色相（红通道显著高于绿蓝）确实是播放头
      expect(best.r, greaterThan(best.g * 2));
      expect(best.r, greaterThan(best.b * 2));
      expect(AppColors.red.g, lessThan(AppColors.red.r),
          reason: '播放头色 token 若改为非红色系，本用例的色相断言需同步调整');
    });
  });
}
