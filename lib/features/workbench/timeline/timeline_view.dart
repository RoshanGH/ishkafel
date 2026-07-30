import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/log/app_log.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';

/// 时间线视图：手势交互 + 缩略图预解码 + 监听编辑器状态重绘
///
/// 缩放本身由外部工具条（slider）驱动，本组件只接收 [geometry] 展示；水平拖拽
/// 命中边界手柄（±6px 容差，见 [TimelineHitTester]）时驱动编辑器移动边界，否则
/// 视为滚动，通过 [onGeometryChanged] 把新的 geometry 上抛给持有状态的父级。
///
/// 单击块体默认选中所在语义单元（粗粒度）；双击镜头轨块体才进入镜头层选中
/// （细粒度编辑入口），点击刻度轨触发 [onSeek]。
///
/// 双击通过在 [onTapUp] 里手动记录上一次点击的时间与位置来判定，不使用
/// [GestureDetector.onDoubleTapDown]：同一个手势识别器上同时挂载双击与水平
/// 拖拽会让 `DoubleTapGestureRecognizer` 占住手势竞技场，拖动的判定被延后
/// 甚至丢失，因此改为在单击回调里自行判断"双击"。
class TimelineView extends StatefulWidget {
  final SegmentationEditorController controller;
  final TimelineGeometry geometry;
  final TimelineMedia? media;
  final int playheadMs;
  final ValueChanged<int> onSeek;
  final ValueChanged<TimelineGeometry> onGeometryChanged;

  const TimelineView({
    super.key,
    required this.controller,
    required this.geometry,
    this.media,
    required this.playheadMs,
    required this.onSeek,
    required this.onGeometryChanged,
  });

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  List<ui.Image>? _thumbImages;
  TimelineHit? _dragHit;
  double _viewportWidth = 0;
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;

  @override
  void initState() {
    super.initState();
    _decodeThumbs(widget.media);
  }

  @override
  void didUpdateWidget(covariant TimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.media, widget.media)) {
      _decodeThumbs(widget.media);
    }
  }

  @override
  void dispose() {
    _disposeThumbImages(_thumbImages);
    super.dispose();
  }

  void _disposeThumbImages(List<ui.Image>? images) {
    if (images == null) return;
    for (final image in images) {
      image.dispose();
    }
  }

  /// 把 [media] 的缩略图文件路径解码为 [ui.Image]；文件不存在或解码失败均跳过
  /// 并记录警告日志（时间线缩略图是辅助视觉，不应阻断审片台）。
  Future<void> _decodeThumbs(TimelineMedia? media) async {
    final paths = media?.thumbPaths ?? const <String>[];
    final decoded = <ui.Image>[];
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) continue;
      try {
        final bytes = await file.readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        decoded.add(frame.image);
      } catch (e) {
        AppLog.warn('时间线缩略图解码失败：$path，$e');
      }
    }
    if (!mounted) {
      _disposeThumbImages(decoded);
      return;
    }
    final previous = _thumbImages;
    setState(() => _thumbImages = decoded);
    _disposeThumbImages(previous);
  }

  void _handleTapUp(TapUpDetails details) {
    final position = details.localPosition;
    final isDoubleTap = _isDoubleTap(position);
    _lastTapTime = DateTime.now();
    _lastTapPosition = position;

    final hit = TimelineHitTester.hitTest(
        position, widget.controller.units, widget.geometry);
    switch (hit) {
      case RulerHit(:final ms):
        widget.onSeek(ms);
      case UnitBlockHit(:final unitIndex):
        widget.controller.select(EditorSelection.unit(unitIndex));
      case ShotBlockHit(:final unitIndex, :final shotIndex):
        // 双击镜头块才进入镜头层选中（细粒度）；单击只选中所在单元（粗粒度）
        widget.controller.select(isDoubleTap
            ? EditorSelection.shot(unitIndex, shotIndex)
            : EditorSelection.unit(unitIndex));
      case UnitBoundaryHit():
      case ShotBoundaryHit():
      case null:
        break;
    }
  }

  /// 与上一次单击的时间间隔在 [kDoubleTapTimeout] 内、位置偏移在
  /// [kDoubleTapSlop] 内即视为双击
  bool _isDoubleTap(Offset position) {
    final lastTime = _lastTapTime;
    final lastPosition = _lastTapPosition;
    if (lastTime == null || lastPosition == null) return false;
    final withinTime = DateTime.now().difference(lastTime) <= kDoubleTapTimeout;
    final withinSlop = (position - lastPosition).distance <= kDoubleTapSlop;
    return withinTime && withinSlop;
  }

  /// 用 onHorizontalDragDown（原始按下位置）而非 onHorizontalDragStart 做命中
  /// 判定：onHorizontalDragStart 要等指针移动超过系统触摸容差（约 18~20px）才
  /// 触发，此时坐标早已偏出边界手柄 ±6px 的判定窗口，会把合法的边界拖拽误判为
  /// 滚动。
  void _handleDragDown(DragDownDetails details) {
    _dragHit = TimelineHitTester.hitTest(
        details.localPosition, widget.controller.units, widget.geometry);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final hit = _dragHit;
    if (hit is UnitBoundaryHit) {
      final ms = widget.geometry.pxToMs(details.localPosition.dx);
      widget.controller.moveUnitBoundary(hit.leftUnitIndex, ms);
      return;
    }
    if (hit is ShotBoundaryHit) {
      final ms = widget.geometry.pxToMs(details.localPosition.dx);
      widget.controller.moveShotBoundary(hit.unitIndex, hit.leftShotIndex, ms);
      return;
    }
    // 未命中边界手柄：整段水平拖拽视为滚动
    final scrolled = widget.geometry
        .scrolledBy(-details.delta.dx, viewportWidthPx: _viewportWidth);
    widget.onGeometryChanged(scrolled);
  }

  void _handleDragEnd(DragEndDetails details) {
    _dragHit = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _handleTapUp,
          onHorizontalDragDown: _handleDragDown,
          onHorizontalDragUpdate: _handleDragUpdate,
          onHorizontalDragEnd: _handleDragEnd,
          child: AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) => CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: TimelinePainter(
                units: widget.controller.units,
                selection: widget.controller.selection,
                geometry: widget.geometry,
                thumbImages: _thumbImages,
                waveEnvelope: widget.media?.waveEnvelope,
                playheadMs: widget.playheadMs,
              ),
            ),
          ),
        );
      },
    );
  }
}
