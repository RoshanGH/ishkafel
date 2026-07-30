import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:ishkafel/app/theme/app_colors.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';

/// 时间线绘制器（无状态纯绘制）
///
/// 绘制刻度尺、单元色块轨、镜头子块轨、缩略图轨、波形轨、播放头，共 6 层，
/// 纵向布局数字全部复用 [TimelineTracks]，不另写一套坐标。
///
/// 缩略图的解码（文件 IO + 生成 [ui.Image]）由 [TimelineView] 负责；本类只
/// 接收已解码的 [thumbImages] 列表进行绘制，保证 CustomPainter 无副作用。
class TimelinePainter extends CustomPainter {
  final List<SemanticUnit> units;
  final EditorSelection? selection;
  final TimelineGeometry geometry;
  final List<ui.Image>? thumbImages;
  final List<double>? waveEnvelope;
  final int playheadMs;

  /// 单元色块 6 色循环
  static const _unitColors = [
    AppColors.accentBlue,
    AppColors.green,
    AppColors.orange,
    AppColors.red,
    AppColors.purple,
    AppColors.textSecondary,
  ];

  const TimelinePainter({
    required this.units,
    required this.selection,
    required this.geometry,
    this.thumbImages,
    this.waveEnvelope,
    required this.playheadMs,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintRuler(canvas, size);
    _paintUnitsTrack(canvas, size);
    _paintShotsTrack(canvas, size);
    _paintThumbsTrack(canvas, size);
    _paintWaveTrack(canvas, size);
    _paintPlayhead(canvas, size);
  }

  void _paintRuler(Canvas canvas, Size size) {
    final stepMs = geometry.rulerStepMs();
    final linePaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, TimelineTracks.rulerBottom),
      Offset(size.width, TimelineTracks.rulerBottom),
      linePaint,
    );

    final startMs = geometry.pxToMs(0);
    final endMs = geometry.pxToMs(size.width);
    final firstTick = (startMs ~/ stepMs) * stepMs;
    for (var ms = firstTick; ms <= endMs; ms += stepMs) {
      final x = geometry.msToPx(ms);
      if (x < -40 || x > size.width + 40) continue;
      canvas.drawLine(
        Offset(x, TimelineTracks.rulerBottom - 6),
        Offset(x, TimelineTracks.rulerBottom),
        linePaint,
      );
      _drawText(canvas, _formatMs(ms), Offset(x + 2, TimelineTracks.rulerTop),
          AppColors.textSecondary,
          fontSize: 10);
    }
  }

  String _formatMs(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _paintUnitsTrack(Canvas canvas, Size size) {
    for (final unit in units) {
      final left = geometry.msToPx(unit.startMs);
      final right = geometry.msToPx(unit.endMs);
      if (right < 0 || left > size.width) continue;

      final rect = Rect.fromLTRB(
          left, TimelineTracks.unitsTop, right, TimelineTracks.unitsBottom);
      final color = _unitColors[unit.index % _unitColors.length];
      final selected = selection != null &&
          selection!.shotIndex == null &&
          selection!.unitIndex == unit.index;

      canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.22));
      canvas.drawRect(
        rect,
        Paint()
          ..color = selected
              ? color.withValues(alpha: 1)
              : color.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 2 : 1,
      );

      canvas.save();
      canvas.clipRect(rect);
      _drawText(
        canvas,
        'U${unit.index + 1} ${unit.transcript}',
        Offset(rect.left + 6, rect.top + 6),
        AppColors.textPrimary,
        fontSize: 12,
        maxWidth: rect.width - 12,
      );
      canvas.restore();
    }
  }

  void _paintShotsTrack(Canvas canvas, Size size) {
    final dividerPaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    final selectedBorder = Paint()
      ..color = AppColors.purple
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (final unit in units) {
      for (var s = 0; s < unit.shots.length; s++) {
        final shot = unit.shots[s];
        final left = geometry.msToPx(shot.startMs);
        final right = geometry.msToPx(shot.endMs);
        if (right < 0 || left > size.width) continue;

        // 内部镜头分隔线（首镜头起点与单元起点重合，已由单元轨绘制，跳过）
        if (s > 0) {
          canvas.drawLine(
            Offset(left, TimelineTracks.shotsTop),
            Offset(left, TimelineTracks.shotsBottom),
            dividerPaint,
          );
        }

        final selected = selection != null &&
            selection!.shotIndex == s &&
            selection!.unitIndex == unit.index;
        if (selected) {
          canvas.drawRect(
            Rect.fromLTRB(left, TimelineTracks.shotsTop, right,
                TimelineTracks.shotsBottom),
            selectedBorder,
          );
        }
      }
    }
  }

  void _paintThumbsTrack(Canvas canvas, Size size) {
    final images = thumbImages;
    if (images == null || images.isEmpty) return;

    final trackRect = Rect.fromLTRB(
        0, TimelineTracks.thumbsTop, size.width, TimelineTracks.thumbsBottom);
    canvas.save();
    canvas.clipRect(trackRect);
    final count = images.length;
    final imagePaint = Paint()..filterQuality = FilterQuality.low;
    for (var i = 0; i < count; i++) {
      final segStartMs = geometry.durationMs * i / count;
      final segEndMs = geometry.durationMs * (i + 1) / count;
      final left = geometry.msToPx(segStartMs.round());
      final right = geometry.msToPx(segEndMs.round());
      if (right < 0 || left > size.width) continue;

      final image = images[i];
      final src =
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
      final dst = Rect.fromLTRB(
          left, TimelineTracks.thumbsTop, right, TimelineTracks.thumbsBottom);
      canvas.drawImageRect(image, src, dst, imagePaint);
    }
    canvas.restore();
  }

  void _paintWaveTrack(Canvas canvas, Size size) {
    final envelope = waveEnvelope;
    if (envelope == null || envelope.isEmpty) return;

    final midY = TimelineTracks.waveTop + TimelineTracks.waveH / 2;
    final barPaint = Paint()..color = AppColors.accentBlue.withValues(alpha: 0.55);
    final count = envelope.length;
    for (var i = 0; i < count; i++) {
      final segStartMs = geometry.durationMs * i / count;
      final segEndMs = geometry.durationMs * (i + 1) / count;
      final left = geometry.msToPx(segStartMs.round());
      final right = geometry.msToPx(segEndMs.round());
      if (right < 0 || left > size.width) continue;

      final halfHeight = envelope[i].clamp(0.0, 1.0) * TimelineTracks.waveH / 2;
      canvas.drawRect(
        Rect.fromLTRB(left, midY - halfHeight, right, midY + halfHeight),
        barPaint,
      );
    }
  }

  void _paintPlayhead(Canvas canvas, Size size) {
    final x = geometry.msToPx(playheadMs);
    if (x < 0 || x > size.width) return;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = AppColors.red
        ..strokeWidth = 2,
    );
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color, {
    double fontSize = 12,
    double? maxWidth,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
    painter.layout(maxWidth: maxWidth ?? double.infinity);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant TimelinePainter oldDelegate) {
    return oldDelegate.units != units ||
        oldDelegate.selection != selection ||
        oldDelegate.geometry != geometry ||
        oldDelegate.thumbImages != thumbImages ||
        oldDelegate.waveEnvelope != waveEnvelope ||
        oldDelegate.playheadMs != playheadMs;
  }
}
