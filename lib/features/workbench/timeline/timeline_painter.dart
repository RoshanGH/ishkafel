import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:ishkafel/app/theme/app_colors.dart';
import 'package:ishkafel/app/theme/app_spacing.dart';
import 'package:ishkafel/app/theme/app_typography.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';

/// 时间线辅助素材（抽帧胶片条 / 音频波形）的就绪状态。
///
/// 抽帧要跑十几次 ffmpeg 子进程、波形要提取整段 PCM，真机实测进页面后约
/// 2 秒才有内容。此前两条轨在这段时间里是纯空白、失败时也是纯空白——
/// 用户无从判断是在算还是坏了。
enum TimelineMediaStatus { loading, ready, failed }

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

  /// 抽帧/波形的就绪状态，决定未就绪时画什么占位
  final TimelineMediaStatus mediaStatus;

  /// 单元色块内标签文字的左右内边距（左右各一份）
  static const _unitLabelPadding = 6.0;

  /// 单元块内两行文字的行距（首行 12px 字号 + 行间呼吸）
  static const _unitLineHeight = 17.0;

  /// 标签窄于这个宽度就不画：只画得下一个省略号，白付文字 layout 的开销
  /// （实测 60 单元 fit 视图下每帧 2.1ms 全花在渲染省略号上）
  static const _minLabelWidth = 24.0;

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
    this.mediaStatus = TimelineMediaStatus.ready,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintRuler(canvas, size);
    _paintTrackLabels(canvas, size);
    _paintUnitsTrack(canvas, size);
    _paintShotsTrack(canvas, size);
    _paintThumbsTrack(canvas, size);
    _paintWaveTrack(canvas, size);
    _paintPlayhead(canvas, size);
  }

  /// 四条轨的标题条。标题同时是操作说明——「视觉镜头严格嵌套在台词语义
  /// 单元内」是本产品的核心约束，写在轨道上比藏进帮助文档有效得多。
  void _paintTrackLabels(Canvas canvas, Size size) {
    final entries = <(double, String, String)>[
      (TimelineTracks.unitsLabelTop, '台词语义单元', '拖大边界调整'),
      (TimelineTracks.shotsLabelTop, '视觉镜头', '拖小边界调整，限制在所属单元内'),
      (TimelineTracks.thumbsLabelTop, '画面', ''),
      (TimelineTracks.waveLabelTop, '音频', ''),
    ];
    for (final (top, title, hint) in entries) {
      _drawText(canvas, title, Offset(AppSpacing.xs, top),
          AppColors.textSecondary,
          fontSize: AppFontSize.micro);
      if (hint.isEmpty) continue;
      _drawText(canvas, '（$hint）', Offset(AppSpacing.xs + 68, top),
          AppColors.textTertiary,
          fontSize: AppFontSize.micro);
    }
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

      // 块体窄到放不下左右内边距时（拖边界产生的亚像素单元），标签无处可画，
      // 直接跳过：此时 `rect.width - 内边距*2` 为负，交给 TextPainter 会在
      // 绘制中途抛异常，让本帧后续所有绘制丢失（见 [_drawText] 文档）。
      final labelMaxWidth = rect.width - _unitLabelPadding * 2;
      if (labelMaxWidth < _minLabelWidth) continue;

      // 两行信息层级：第一行是定位用的编号与时长（扫读时先找它），
      // 第二行才是台词摘要。挤成一行时编号会被长台词淹没。
      canvas.save();
      canvas.clipRect(rect);
      final textLeft = rect.left + _unitLabelPadding;
      _drawText(
        canvas,
        _unitHeadline(unit),
        Offset(textLeft, rect.top + AppSpacing.xs),
        AppColors.textPrimary,
        fontSize: AppFontSize.body,
        maxWidth: labelMaxWidth,
      );
      _drawText(
        canvas,
        unit.transcript,
        Offset(textLeft, rect.top + AppSpacing.xs + _unitLineHeight),
        AppColors.textSecondary,
        fontSize: AppFontSize.caption,
        maxWidth: labelMaxWidth,
      );
      canvas.restore();
    }
  }

  /// 单元块首行：编号 + 标签（打标接通后）或时长
  String _unitHeadline(SemanticUnit unit) {
    final id = 'U${unit.index + 1}';
    if (unit.tags.isNotEmpty) return '$id ${unit.tags.first}';
    final seconds = (unit.endMs - unit.startMs) / 1000;
    return '$id · ${seconds.toStringAsFixed(1)}s';
  }

  /// 相邻镜头块体之间的视觉间隙（左右各内缩一半）
  static const _shotGap = 2.0;

  /// 镜头编号标签的左内边距
  static const _shotLabelPadding = 4.0;

  /// 波形按像素列重采样时每根柱子的宽度。取 2px 而不是 1px：
  /// 1px 柱在 Retina 上会被抗锯齿糊掉，2px 既清晰又足够密。
  static const _waveColumnWidth = 2.0;

  /// 画视觉镜头轨：每个镜头一个独立块体。
  ///
  /// 块体填充沿用**所属台词语义单元的颜色**（低透明度），让"视觉镜头严格
  /// 嵌套在语义单元内"这条核心约束在视觉上一眼可见；选中态改用紫色实心
  /// 高亮，与单元轨的选中态（单元自身色描边加粗）区分开。
  void _paintShotsTrack(Canvas canvas, Size size) {
    for (final unit in units) {
      final unitColor = _unitColors[unit.index % _unitColors.length];
      for (var s = 0; s < unit.shots.length; s++) {
        final shot = unit.shots[s];
        final left = geometry.msToPx(shot.startMs);
        final right = geometry.msToPx(shot.endMs);
        if (right < 0 || left > size.width) continue;

        // 内缩出相邻块体之间的间隙；块体本身比间隙还窄时不再内缩，
        // 否则会得到零宽甚至负宽的矩形
        final inset = (right - left) > _shotGap * 2 ? _shotGap / 2 : 0.0;
        final rect = Rect.fromLTRB(left + inset, TimelineTracks.shotsTop,
            right - inset, TimelineTracks.shotsBottom);

        final selected = selection != null &&
            selection!.shotIndex == s &&
            selection!.unitIndex == unit.index;

        canvas.drawRect(
          rect,
          Paint()
            ..color = selected
                ? AppColors.purple.withValues(alpha: 0.42)
                : unitColor.withValues(alpha: 0.16),
        );
        canvas.drawRect(
          rect,
          Paint()
            ..color = selected
                ? AppColors.purple
                : unitColor.withValues(alpha: 0.5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = selected ? 2 : 1,
        );

        // 放不下编号就只留块体（负数 maxWidth 会让整帧绘制中断，见 [_drawText]）
        final labelMaxWidth = rect.width - _shotLabelPadding * 2;
        if (labelMaxWidth <= 0) continue;

        canvas.save();
        canvas.clipRect(rect);
        _drawText(
          canvas,
          'S${s + 1}',
          Offset(rect.left + _shotLabelPadding, rect.top + 6),
          selected ? AppColors.textPrimary : AppColors.textSecondary,
          fontSize: 10,
          maxWidth: labelMaxWidth,
        );
        canvas.restore();
      }
    }
  }

  void _paintThumbsTrack(Canvas canvas, Size size) {
    final images = thumbImages;
    if (images == null || images.isEmpty) {
      _paintTrackPlaceholder(canvas, size, TimelineTracks.thumbsTop,
          TimelineTracks.thumbsBottom, '画面缩略图');
      return;
    }

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
      final dst = Rect.fromLTRB(
          left, TimelineTracks.thumbsTop, right, TimelineTracks.thumbsBottom);
      canvas.drawImageRect(image, _coverSrcRect(image, dst), dst, imagePaint);
    }
    canvas.restore();
  }

  /// 按 cover 规则算出源图裁剪区：等比填满目标格，多出的部分居中裁掉。
  ///
  /// 本项目的工作对象是 9:16 竖屏成片，而胶片条格子是宽扁的（约 100×52），
  /// 直接把整张源图拉进目标矩形会横向拉伸约 3.4 倍，人脸全变形——这与
  /// CLAUDE.md「竖屏素材为主要工作对象」的定位直接冲突。
  Rect _coverSrcRect(ui.Image image, Rect dst) {
    final srcW = image.width.toDouble();
    final srcH = image.height.toDouble();
    if (dst.width <= 0 || dst.height <= 0) {
      return Rect.fromLTWH(0, 0, srcW, srcH);
    }
    final dstAspect = dst.width / dst.height;
    final srcAspect = srcW / srcH;
    if (srcAspect > dstAspect) {
      // 源图更宽：保留全高，横向居中裁剪
      final keepW = srcH * dstAspect;
      return Rect.fromLTWH((srcW - keepW) / 2, 0, keepW, srcH);
    }
    // 源图更高（竖屏素材的常态）：保留全宽，纵向居中裁剪
    final keepH = srcW / dstAspect;
    return Rect.fromLTWH(0, (srcH - keepH) / 2, srcW, keepH);
  }

  /// 媒体未就绪时的轨道占位：避免整条轨一片空白被误认为"这栏坏了"。
  /// 加载中与失败给不同的措辞与颜色，让用户能区分「在算」与「算失败了」。
  void _paintTrackPlaceholder(
      Canvas canvas, Size size, double top, double bottom, String what) {
    if (mediaStatus == TimelineMediaStatus.ready) return;
    final rect = Rect.fromLTRB(0, top, size.width, bottom);
    final failed = mediaStatus == TimelineMediaStatus.failed;
    canvas.drawRect(
      rect,
      Paint()
        ..color = (failed ? AppColors.red : AppColors.textTertiary)
            .withValues(alpha: 0.10),
    );
    _drawText(
      canvas,
      failed ? '$what生成失败' : '$what生成中…',
      Offset(AppSpacing.sm, top + (bottom - top) / 2 - 7),
      failed ? AppColors.red : AppColors.textSecondary,
      fontSize: AppFontSize.caption,
      maxWidth: size.width - AppSpacing.sm * 2,
    );
  }

  void _paintWaveTrack(Canvas canvas, Size size) {
    final envelope = waveEnvelope;
    if (envelope == null || envelope.isEmpty) {
      _paintTrackPlaceholder(canvas, size, TimelineTracks.waveTop,
          TimelineTracks.waveBottom, '音频波形');
      return;
    }

    // 按**可视像素列**重采样，而不是按包络桶逐个画矩形。
    //
    // 按桶画时，柱子的疏密取决于「桶数 ÷ 片长」这个固定值：5 分钟素材放大
    // 20 倍后视口只覆盖 15 秒，里面只落得下约 100 个桶，于是满屏只有 100 根
    // 等高的宽柱——而用户放大波形恰恰是为了看清语句之间的停顿，宽柱内部
    // 没有任何起伏可看。按像素列取该列覆盖时间范围内的包络峰值，柱子密度
    // 就与缩放无关，始终铺满视口。
    final midY = TimelineTracks.waveTop + TimelineTracks.waveH / 2;
    final barPaint =
        Paint()..color = AppColors.accentBlue.withValues(alpha: 0.55);
    final count = envelope.length;
    final durationMs = geometry.durationMs;
    if (durationMs <= 0) return;

    for (var x = 0.0; x < size.width; x += _waveColumnWidth) {
      final startMs = geometry.pxToMs(x);
      final endMs = geometry.pxToMs(x + _waveColumnWidth);
      if (endMs < 0 || startMs > durationMs) continue;

      // 该像素列覆盖的包络下标范围（至少取一个样本，避免高倍放大下取空）
      var from = (count * startMs / durationMs).floor().clamp(0, count - 1);
      var to = (count * endMs / durationMs).ceil().clamp(1, count);
      if (to <= from) to = from + 1;

      var peak = 0.0;
      for (var i = from; i < to; i++) {
        final v = envelope[i];
        if (v > peak) peak = v;
      }

      final halfHeight = peak.clamp(0.0, 1.0) * TimelineTracks.waveH / 2;
      canvas.drawRect(
        Rect.fromLTRB(x, midY - halfHeight, x + _waveColumnWidth, midY + halfHeight),
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

  /// 画一行单行省略文字。
  ///
  /// [maxWidth] 一律夹紧到非负：`TextPainter.layout` 内部会执行
  /// `clampDouble(行宽, minWidth = 0, maxWidth)`，而 `clampDouble` 断言
  /// `min <= max`，负数会直接抛 `AssertionError`。该异常发生在
  /// `CustomPainter.paint` 中途，被 `RenderObject._paintWithContext` 吞进
  /// 「rendering library」错误通道，屏幕上的表现是**本帧从抛点起的所有绘制
  /// 全部丢失**——不仅是时间线剩余的镜头/抽帧/波形轨，还包括 `Scaffold` 里
  /// 晚于 body 绘制的顶栏与底部栏（控件仍在树里、布局与命中测试都正常，
  /// 只是画不出来）。因此这里把夹紧放在绘制边界上兜底，调用方另有各自的
  /// 「放不下就不画」判断。
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
    painter.layout(maxWidth: math.max(0, maxWidth ?? double.infinity));
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant TimelinePainter oldDelegate) {
    return oldDelegate.units != units ||
        oldDelegate.selection != selection ||
        oldDelegate.geometry != geometry ||
        oldDelegate.mediaStatus != mediaStatus ||
        oldDelegate.thumbImages != thumbImages ||
        oldDelegate.waveEnvelope != waveEnvelope ||
        oldDelegate.playheadMs != playheadMs;
  }
}
