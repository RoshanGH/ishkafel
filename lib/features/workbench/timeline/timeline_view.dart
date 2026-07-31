import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
/// [GestureDetector.onDoubleTapDown]：同一个手势识别器上同时挂载双击与单击/拖拽
/// 会让 `DoubleTapGestureRecognizer` 在竞技场里持有指针，测试结束时它仍握着一个
/// 未消解的 [kDoubleTapTimeout]（300ms）倒计时定时器，触发测试框架的
/// "timer still pending" 检查失败；因此改为在单击回调里自行判断"双击"。
///
/// 拖拽起点的坐标读取使用 [DragStartBehavior.down]（见 [GestureDetector] 构造），
/// 让 [onHorizontalDragStart] 报告的是指针刚按下时的原始坐标，而非默认
/// [DragStartBehavior.start] 下"越过系统触摸容差（约 18~20px）后手势识别器胜出
/// 时"的坐标——边界手柄的命中容差只有 ±6px，用默认行为会把合法的边界拖拽误判
/// 成滚动。这与双击定时器泄漏是两个独立问题。
///
/// 命中边界手柄时会开启一个"拖拽会话"（[SegmentationEditorController.
/// beginDragSession]/[endDragSession]）：一次连续拖拽会触发几十次
/// [onHorizontalDragUpdate]，若每次都单独调用 moveUnitBoundary/moveShotBoundary
/// 都各自入 undo 栈，用户要撤销几十次才能回退一次拖动；会话期间的移动不逐次
/// 入栈，拖拽结束时才合并为一条记录。
class TimelineView extends StatefulWidget {
  final SegmentationEditorController controller;
  final TimelineGeometry geometry;
  final TimelineMedia? media;
  /// 播放位置。用 [ValueListenable] 而不是普通 int：播放时它每秒变化 30 次，
  /// 只让包住 [CustomPaint] 的那一层重建，外层三栏面板完全不动。
  final ValueListenable<int> playhead;

  /// 抽帧/波形就绪状态，未就绪时时间线画占位而不是留白
  final TimelineMediaStatus mediaStatus;
  final ValueChanged<int> onSeek;
  final ValueChanged<TimelineGeometry> onGeometryChanged;

  /// 只读回看模式（评审 Important 1）：true 时忽略会改数据的手势（边界
  /// 拖拽），但保留选中、滚动、缩放、点刻度 seek——回看仍要能浏览。
  /// 默认 false（编辑态，行为与此前一致）。
  final bool readOnly;

  const TimelineView({
    super.key,
    required this.controller,
    required this.geometry,
    this.media,
    required this.playhead,
    this.mediaStatus = TimelineMediaStatus.ready,
    required this.onSeek,
    required this.onGeometryChanged,
    this.readOnly = false,
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

  /// 单击镜头块后延迟到双击窗口超时才执行的"选中所在单元"任务；若窗口内
  /// 来了第二击，则取消该任务、直接选中镜头层，避免选中态先跳单元再跳镜头
  /// 的闪烁。
  Timer? _pendingUnitSelectTimer;

  /// 缩略图解码请求的递增序号：连续两次 media 变更时，慢的那次解码结果到达
  /// 时已不是最新请求，需丢弃并 dispose，避免覆盖新结果（竞态）。
  int _decodeRequestId = 0;

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
    _pendingUnitSelectTimer?.cancel();
    // 兜底：若卸载发生在拖拽会话进行中（Flutter 手势系统在卸载路径下不保证
    // onHorizontalDragEnd/onHorizontalDragCancel 一定会触发），必须显式结束
    // 会话，否则 controller._dragSessionSnapshot 永久非空，此后所有编辑都会
    // 静默跳过 undo 入栈，用户撤销功能彻底失效且无任何提示。该方法本身是
    // 幂等的：不在会话中调用无副作用。
    widget.controller.endDragSession();
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
  ///
  /// 用递增的 [_decodeRequestId] 作为"取消令牌"：解码是异步 IO，若 media 连续
  /// 变更两次，先发出的慢请求可能比后发出的快请求更晚完成；写回前比对请求号，
  /// 不是最新请求就丢弃解码结果（并 dispose），不覆盖新结果。
  Future<void> _decodeThumbs(TimelineMedia? media) async {
    final requestId = ++_decodeRequestId;
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
    if (!mounted || requestId != _decodeRequestId) {
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
        _cancelPendingUnitSelect();
        widget.onSeek(ms);
      case UnitBlockHit(:final unitIndex):
        _cancelPendingUnitSelect();
        widget.controller.select(EditorSelection.unit(unitIndex));
      case ShotBlockHit(:final unitIndex, :final shotIndex):
        if (isDoubleTap) {
          // 双击：取消尚未触发的"选中单元"延迟任务，直接进入镜头层选中，
          // 避免选中态先跳单元再跳镜头的闪烁
          _cancelPendingUnitSelect();
          widget.controller.select(EditorSelection.shot(unitIndex, shotIndex));
        } else {
          // 单击：不立即选中单元，先等一个双击窗口——如果双击窗口内没有
          // 第二击，才真正选中所在单元（粗粒度）
          _schedulePendingUnitSelect(unitIndex);
        }
      case UnitBoundaryHit():
      case ShotBoundaryHit():
      case null:
        _cancelPendingUnitSelect();
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

  void _schedulePendingUnitSelect(int unitIndex) {
    _cancelPendingUnitSelect();
    _pendingUnitSelectTimer = Timer(kDoubleTapTimeout, () {
      _pendingUnitSelectTimer = null;
      widget.controller.select(EditorSelection.unit(unitIndex));
    });
  }

  void _cancelPendingUnitSelect() {
    _pendingUnitSelectTimer?.cancel();
    _pendingUnitSelectTimer = null;
  }

  /// 命中边界手柄时开启拖拽会话（多次 update 合并为一条撤销记录）；
  /// [DragStartBehavior.down]（见 [build]）确保这里拿到的是指针刚按下时的
  /// 原始坐标，落在边界手柄 ±6px 的判定窗口内。
  void _handleDragStart(DragStartDetails details) {
    // 只读模式下不识别边界手柄命中（视为普通滚动手势），从而忽略会改数据
    // 的边界拖拽，同时仍保留滚动能力（见 _handleDragUpdate 的 else 分支）。
    final hit = widget.readOnly
        ? null
        : TimelineHitTester.hitTest(
            details.localPosition, widget.controller.units, widget.geometry);
    _dragHit = hit;
    if (hit is UnitBoundaryHit || hit is ShotBoundaryHit) {
      widget.controller.beginDragSession();
    }
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

  void _endDrag() {
    _dragHit = null;
    // 不在会话中时调用无副作用；在会话中则把本次拖拽合并为一条撤销记录
    widget.controller.endDragSession();
  }

  void _handleDragEnd(DragEndDetails details) => _endDrag();

  void _handleDragCancel() => _endDrag();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 让 onHorizontalDragStart 报告指针刚按下时的原始坐标（而非默认的
          // "越过触摸容差后手势识别器胜出时"的坐标），边界手柄 ±6px 的命中
          // 判定才不会被拖拽启动阈值带偏
          dragStartBehavior: DragStartBehavior.down,
          onTapUp: _handleTapUp,
          onHorizontalDragStart: _handleDragStart,
          onHorizontalDragUpdate: _handleDragUpdate,
          onHorizontalDragEnd: _handleDragEnd,
          onHorizontalDragCancel: _handleDragCancel,
          // RepaintBoundary 是必需的：没有它时 RenderCustomPaint.markNeedsPaint
          // 会一路上溯到 RenderView，播放头每次移动都要把整页的绘制指令重录一遍。
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) => ValueListenableBuilder<int>(
                valueListenable: widget.playhead,
                builder: (context, playheadMs, _) => CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: TimelinePainter(
                    units: widget.controller.units,
                    selection: widget.controller.selection,
                    geometry: widget.geometry,
                    thumbImages: _thumbImages,
                    waveEnvelope: widget.media?.waveEnvelope,
                    playheadMs: playheadMs,
                    mediaStatus: widget.mediaStatus,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
