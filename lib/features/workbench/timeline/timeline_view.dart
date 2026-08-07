import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/log/app_log.dart';
import 'package:ishkafel/features/workbench/timeline/bgm_track.dart';
import 'package:ishkafel/features/workbench/timeline/text_layout_cache.dart';
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

  /// 开始/结束拖动播放头。调用方据此暂停播放并在松手后恢复——
  /// 拖动时画面若还在自己往前走，用户根本对不准位置。
  final VoidCallback? onScrubStart;
  final VoidCallback? onScrubEnd;

  /// 双击某一块：从它的起点播到它的终点（含头不含尾，单位毫秒）。
  /// 逐段试看是审片的主要动作，比「从这里一直播下去」有用得多。
  final void Function(int startMs, int endMs)? onPlaySegment;

  /// 配乐方案（画在配乐轨上）
  final BgmPlan bgm;

  /// 换音色方案（换过的单元在块体底边画一道绿杠）
  final VoicePlan voices;

  /// 当前替换方案：时间线上标出「哪几段挑好了素材、各几条」
  final List<UnitReplacement> replacements;

  /// 被整体替换的单元在成片里有多长（单元下标 → 毫秒）
  final Map<int, int> composedDurations;

  /// 点了那个数字徽标：跳到右栏对应的那一段（shotIndex 为 null 表示整体替换）
  final void Function(int unitIndex, int? shotIndex)? onReplacementBadgeTap;

  /// 在配乐轨上框选完一段连续镜头（全片打平下标，含两端）
  final void Function(int fromShot, int toShot)? onBgmRangeSelected;

  /// 点了配乐轨上已有的一段（用于换曲/移除）
  final void Function(BgmSegment segment)? onBgmSegmentTap;

  /// 判定双击窗口用的时钟。测试注入——`tester.pump(Duration)` 推进的是框架的
  /// 假时钟，`DateTime.now()` 纹丝不动，不注入就没法验证「隔太久不算双击」。
  final DateTime Function() clock;

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
    this.onScrubStart,
    this.onScrubEnd,
    this.onPlaySegment,
    this.bgm = BgmPlan.empty,
    this.voices = VoicePlan.empty,
    this.replacements = const [],
    this.composedDurations = const {},
    this.onReplacementBadgeTap,
    this.onBgmRangeSelected,
    this.onBgmSegmentTap,
    DateTime Function()? clock,
    this.readOnly = false,
  }) : clock = clock ?? DateTime.now;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  List<ui.Image?>? _thumbImages;
  TimelineHit? _dragHit;

  /// 正在配乐轨上框选的镜头区间（起点下标 / 当前下标）。
  /// 非空即表示这次拖拽是在选配乐区间，不是拖边界也不是滚动。
  ({int from, int to})? _bgmSelecting;

  /// 本次拖拽是「拖播放头」而不是「拖时间线」
  bool _scrubbing = false;
  double _viewportWidth = 0;
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;

  /// 缩略图解码请求的递增序号：连续两次 media 变更时，慢的那次解码结果到达
  /// 时已不是最新请求，需丢弃并 dispose，避免覆盖新结果（竞态）。
  int _decodeRequestId = 0;

  /// 跨帧复用的文字排版缓存（时间线每帧几十段文字，内容几乎不变）
  final _textCache = TextLayoutCache();

  @override
  void initState() {
    super.initState();
    _decodeThumbs(widget.media);
    widget.playhead.addListener(_followPlayhead);
  }

  @override
  void didUpdateWidget(covariant TimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.media, widget.media)) {
      _decodeThumbs(widget.media);
    }
    if (!identical(oldWidget.playhead, widget.playhead)) {
      oldWidget.playhead.removeListener(_followPlayhead);
      widget.playhead.addListener(_followPlayhead);
    }
  }

  /// 播放头跑出可视区时把它带回来（对标剪映/FCP 的时间线跟随）。
  ///
  /// 放大之后视口只覆盖全片的一小段，一播放播放头几秒就跑到视口外，用户
  /// 要么手动追着滚、要么只能缩回 fit——放大功能等于废掉一半。
  ///
  /// 只在**跑出去**时才滚（还在视野里就不动），避免每帧微调让画面无谓抖动。
  /// 滚动后把播放头放在视口靠左三分之一处，留出更多"接下来要播的内容"，
  /// 这是视频工具的通行做法。
  ///
  /// 用户手动平移/缩放后临时停跟随（[_followSuspended]）：否则播放中想看看
  /// 别处，下一个 tick（≤33ms）就把视口拽回去，等于不让人看。播放头重新
  /// 进入视野时视为"用户已经追上"，自动恢复跟随——暂停不能是永久的，
  /// 否则浏览过一次之后播放头就再也不会被带回来。
  void _followPlayhead() {
    if (_viewportWidth <= 0) return;
    final geometry = widget.geometry;
    // fit 状态下整片都在视口里，没有滚动余地
    if (geometry.totalWidthPx <= _viewportWidth) return;

    final x = geometry.msToPx(widget.playhead.value);
    if (x >= 0 && x <= _viewportWidth) {
      _followSuspended = false;
      return;
    }
    if (_followSuspended) return;

    final targetScroll = geometry.msToPx(widget.playhead.value) +
        geometry.scrollPx -
        _viewportWidth / 3;
    final next = geometry.scrolledBy(targetScroll - geometry.scrollPx,
        viewportWidthPx: _viewportWidth);
    widget.onGeometryChanged(next);
  }

  @override
  void dispose() {
    _textCache.clear();
    widget.playhead.removeListener(_followPlayhead);
    // 兜底：若卸载发生在拖拽会话进行中（Flutter 手势系统在卸载路径下不保证
    // onHorizontalDragEnd/onHorizontalDragCancel 一定会触发），必须显式结束
    // 会话，否则 controller._dragSessionSnapshot 永久非空，此后所有编辑都会
    // 静默跳过 undo 入栈，用户撤销功能彻底失效且无任何提示。该方法本身是
    // 幂等的：不在会话中调用无副作用。
    widget.controller.endDragSession();
    _disposeThumbImages(_thumbImages);
    super.dispose();
  }

  void _disposeThumbImages(List<ui.Image?>? images) {
    if (images == null) return;
    for (final image in images) {
      image?.dispose();
    }
  }

  /// 把 [media] 的缩略图文件路径解码为 [ui.Image]；文件不存在或解码失败均跳过
  /// 并记录警告日志（时间线缩略图是辅助视觉，不应阻断审片台）。
  ///
  /// 用递增的 [_decodeRequestId] 作为"取消令牌"：解码是异步 IO，若 media 连续
  /// 变更两次，先发出的慢请求可能比后发出的快请求更晚完成；写回前比对请求号，
  /// 不是最新请求就丢弃解码结果（并 dispose），不覆盖新结果。
  /// 解码结果**按下标对齐**：某一张缺失或解码失败时保留 null 占位，绝不
  /// 压缩列表——压缩会让剩余各张被按新长度重新等分铺开，整条胶片条与
  /// 时间轴错位（见 [TimelineMedia.thumbPaths] 的说明）。
  Future<void> _decodeThumbs(TimelineMedia? media) async {
    final requestId = ++_decodeRequestId;
    final paths = media?.thumbPaths ?? const <String?>[];
    final decoded = List<ui.Image?>.filled(paths.length, null);
    for (var i = 0; i < paths.length; i++) {
      final path = paths[i];
      if (path == null) continue;
      final file = File(path);
      if (!await file.exists()) continue;
      try {
        final bytes = await file.readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        decoded[i] = frame.image;
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
    _lastTapTime = widget.clock();
    _lastTapPosition = position;

    final units = widget.controller.units;
    // 替换数量徽标优先命中：它压在块体上，先判它才点得到
    if (_hitReplacementBadge(position)) return;
    if (_isOnBgmTrack(position)) {
      final at = _unitIndexAtX(position.dx);
      final segment = at == null ? null : widget.bgm.segmentAt(at);
      if (segment != null) widget.onBgmSegmentTap?.call(segment);
      return;
    }

    final hit = TimelineHitTester.hitTest(
        position, widget.controller.units, widget.geometry);
    switch (hit) {
      case RulerHit(:final ms):
        widget.onSeek(ms);
      case UnitBlockHit(:final unitIndex):
        // 单击点什么选什么，立即生效。原来单击镜头选的是「所在单元」，
        // 而且要等 300ms 双击窗口超时才生效——点下去没反应，用户只会以为
        // 没点上；想选单元点上面这一行就是了，那层粗粒度兜底是多余的。
        widget.controller.select(EditorSelection.unit(unitIndex));
        if (isDoubleTap && unitIndex < units.length) {
          final unit = units[unitIndex];
          widget.onPlaySegment?.call(unit.startMs, unit.endMs);
        }
      case ShotBlockHit(:final unitIndex, :final shotIndex):
        widget.controller.select(EditorSelection.shot(unitIndex, shotIndex));
        if (isDoubleTap &&
            unitIndex < units.length &&
            shotIndex < units[unitIndex].shots.length) {
          final shot = units[unitIndex].shots[shotIndex];
          widget.onPlaySegment?.call(shot.startMs, shot.endMs);
        }
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
    final withinTime = widget.clock().difference(lastTime) <= kDoubleTapTimeout;
    final withinSlop = (position - lastPosition).distance <= kDoubleTapSlop;
    return withinTime && withinSlop;
  }

  /// 命中边界手柄时开启拖拽会话（多次 update 合并为一条撤销记录）；
  /// [DragStartBehavior.down]（见 [build]）确保这里拿到的是指针刚按下时的
  /// 原始坐标，落在边界手柄 ±6px 的判定窗口内。
  void _handleDragStart(DragStartDetails details) {
    // 拖播放头优先于一切：它只是定位、不改数据，因此只读回看下同样可用。
    // 判定放在边界命中之前——刻度尺本来就不承载任何边界手柄，不会打架。
    if (_isScrubStart(details.localPosition)) {
      _scrubbing = true;
      _dragHit = null;
      widget.onScrubStart?.call();
      _seekTo(details.localPosition.dx);
      return;
    }
    // 配乐轨上横向拖拽 = 框选一段连续镜头。判定放在边界命中之前：配乐轨
    // 上本来就没有边界手柄，不会打架。
    if (!widget.readOnly && _isOnBgmTrack(details.localPosition)) {
      final at = _unitIndexAtX(details.localPosition.dx);
      if (at != null) {
        setState(() => _bgmSelecting = (from: at, to: at));
        _dragHit = null;
        return;
      }
    }
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

  /// 播放头的抓取半径。比边界手柄（±6px）宽一些：红线是贯穿全高的醒目目标，
  /// 用户会直接往上按，抓不住比抓错更让人恼火。
  static const double _playheadGrabPx = 8;

  /// 两处可以起拖播放头：刻度尺整条（专业剪辑软件的通行做法），
  /// 以及红线本身左右各 [_playheadGrabPx]（用户看见什么就去拖什么）。
  bool _isScrubStart(Offset position) {
    if (position.dy >= TimelineTracks.rulerTop &&
        position.dy < TimelineTracks.rulerBottom) {
      return true;
    }
    final playheadX = widget.geometry.msToPx(widget.playhead.value);
    return (position.dx - playheadX).abs() <= _playheadGrabPx;
  }

  /// 像素 → 毫秒（[TimelineGeometry.pxToMs] 已夹在 [0, durationMs]，
  /// 拖出两端不会出现负数或超长）
  void _seekTo(double dx) => widget.onSeek(widget.geometry.pxToMs(dx));

  /// 点在某个替换数量徽标上了吗？是的话跳到右栏对应的那一段。
  bool _hitReplacementBadge(Offset position) {
    final onBadge = widget.onReplacementBadgeTap;
    if (onBadge == null) return false;

    for (final unit in widget.controller.units) {
      final rect = Rect.fromLTRB(
        widget.geometry.msToPx(unit.startMs),
        TimelineTracks.unitsTop,
        widget.geometry.msToPx(unit.endMs),
        TimelineTracks.unitsBottom,
      );
      // 没挑素材的地方压根没画徽标，点下去不该误跳
      final hasWhole =
          ReplacementBadges.wholeCount(widget.replacements, unit.index) > 0;
      if (hasWhole &&
          (ReplacementBadges.unitBadgeRect(rect)?.contains(position) ?? false)) {
        onBadge(unit.index, null);
        return true;
      }
      for (var s = 0; s < unit.shots.length; s++) {
        final shot = unit.shots[s];
        final shotRect = Rect.fromLTRB(
          widget.geometry.msToPx(shot.startMs),
          TimelineTracks.shotsTop,
          widget.geometry.msToPx(shot.endMs),
          TimelineTracks.shotsBottom,
        );
        final hasShot =
            ReplacementBadges.shotCount(widget.replacements, unit.index, s) > 0;
        if (hasShot &&
            (ReplacementBadges.shotBadgeRect(shotRect)?.contains(position) ??
                false)) {
          onBadge(unit.index, s);
          return true;
        }
      }
    }
    return false;
  }

  bool _isOnBgmTrack(Offset position) =>
      position.dy >= TimelineTracks.bgmTop &&
      position.dy < TimelineTracks.bgmBottom;

  /// 配乐轨按台词语义单元对齐——框选时吸附到单元边界，而不是 51 个镜头
  /// 一格一格对
  int? _unitIndexAtX(double dx) => unitIndexAtMs(
      widget.controller.units, widget.geometry.pxToMs(dx));

  void _handleDragUpdate(DragUpdateDetails details) {
    if (_bgmSelecting case final sel?) {
      final at = _unitIndexAtX(details.localPosition.dx);
      if (at != null && at != sel.to) {
        setState(() => _bgmSelecting = (from: sel.from, to: at));
      }
      return;
    }
    if (_scrubbing) {
      // 每次 update 都定位：只在松手时跳一次，等于让用户闭着眼睛拖
      _seekTo(details.localPosition.dx);
      return;
    }
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
    if (_bgmSelecting case final sel?) {
      setState(() => _bgmSelecting = null);
      widget.onBgmRangeSelected?.call(
          sel.from < sel.to ? sel.from : sel.to,
          sel.from < sel.to ? sel.to : sel.from);
      return;
    }
    if (_scrubbing) {
      _scrubbing = false;
      // 少发一次 end，调用方那边的播放就永远恢复不回来
      widget.onScrubEnd?.call();
    }
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
        return Listener(
          onPointerSignal: _handlePointerSignal,
          onPointerPanZoomStart: (_) {
            _panZoomScale = 1.0;
            _panZoomPan = Offset.zero;
          },
          onPointerPanZoomUpdate: _handlePanZoomUpdate,
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 触控板的双指手势交给 Listener 的 PanZoom 回调统一处理。
          // 若同时让手势识别器把它当成拖拽，两条路径会各自基于**同一份未更新
          // 的 geometry** 调用 onGeometryChanged，后到的那次把先到的结果整个
          // 覆盖掉——表现为捏合缩放看起来完全没生效。
          // 注意：在触控板上按下拖动产生的是 mouse 类指针，不受这里影响。
          supportedDevices: const {
            PointerDeviceKind.mouse,
            PointerDeviceKind.touch,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
            PointerDeviceKind.unknown,
          },
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
          // 轨道总高是固定的（四条轨 + 各自标题条 = 248px）。窗口太矮时
          // 纵向滚动兜底，而不是让最后一条轨（音频波形）整条落在可视区外——
          // 用户既看不到波形，也看不到为它准备的「生成中/生成失败」占位。
          // 手势坐标取自 CustomPaint 内部，滚动不影响命中判定的 y 基准。
          child: SingleChildScrollView(
            child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) => ValueListenableBuilder<int>(
                valueListenable: widget.playhead,
                builder: (context, playheadMs, _) => CustomPaint(
                  size: Size(
                    constraints.maxWidth,
                    math.max(constraints.maxHeight, TimelineTracks.totalHeight),
                  ),
                  painter: TimelinePainter(
                    units: widget.controller.units,
                    selection: widget.controller.selection,
                    geometry: widget.geometry,
                    thumbImages: _thumbImages,
                    waveEnvelope: widget.media?.waveEnvelope,
                    playheadMs: playheadMs,
                    mediaStatus: widget.mediaStatus,
                    bgm: widget.bgm,
                    bgmSelecting: _bgmSelecting,
                    voices: widget.voices,
                    replacements: widget.replacements,
                    composedDurations: widget.composedDurations,
                    textCache: _textCache,
                  ),
                ),
              ),
            ),
          ),
          ),
        ),
        );
      },
    );
  }

  /// 滚轮 / 触控板双指手势：
  /// - ⌘ + 滚动 → 以指针位置为锚点缩放（macOS 上缩放的通行手势）
  /// - 其余滚动（含纵向）→ 平移时间线
  ///
  /// 纵向滚动也映射为平移：时间线本身没有纵向可滚内容，不映射就是一个
  /// 落空的手势；而触控板上纯粹的水平滑动很难做到，用户实际会带纵向分量。
  /// 用户手动平移/缩放后临时停止跟随播放头；播放头重新进入视野时解除
  bool _followSuspended = false;

  /// 触控板双指手势上一次的累计缩放比例与累计平移（事件给的是自手势开始
  /// 以来的累计值，需要自己算增量）
  double _panZoomScale = 1.0;
  Offset _panZoomPan = Offset.zero;

  /// 触控板双指手势：平移 + 捏合缩放，一处统一处理。
  ///
  /// 两件事必须在同一处做：它们来自同一个事件流，若分散在两条路径里，各自
  /// 基于同一份未更新的 geometry 计算并回调，后者会把前者的结果覆盖掉。
  void _handlePanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (_viewportWidth <= 0) return;

    final scale = event.scale <= 0 ? _panZoomScale : event.scale;
    final factor = scale / _panZoomScale;
    final panDelta = event.pan - _panZoomPan;
    _panZoomScale = scale;
    _panZoomPan = event.pan;

    var next = widget.geometry;
    // 极小的抖动不触发重算，避免手指静止时的噪声让画面持续微动
    if ((factor - 1).abs() >= 0.005) {
      next = next.zoomAt(event.localPosition.dx, factor,
          viewportWidthPx: _viewportWidth);
    }
    if (panDelta.dx.abs() >= 0.5) {
      // 内容跟着手指走：手指左滑（dx 为负）时时间线向右滚
      next = next.scrolledBy(-panDelta.dx, viewportWidthPx: _viewportWidth);
    }
    if (identical(next, widget.geometry)) return;
    _followSuspended = true;
    widget.onGeometryChanged(next);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (_viewportWidth <= 0) return;

    final zooming = HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    if (zooming) {
      // 向上滚（dy<0）放大。每 100 单位对应 1.2 倍，手感与系统一致
      final steps = -event.scrollDelta.dy / 100;
      if (steps == 0) return;
      final factor = math.pow(1.2, steps).toDouble();
      _followSuspended = true;
      widget.onGeometryChanged(widget.geometry.zoomAt(
          event.localPosition.dx, factor,
          viewportWidthPx: _viewportWidth));
      return;
    }

    final delta = event.scrollDelta.dx.abs() >= event.scrollDelta.dy.abs()
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta == 0) return;
    _followSuspended = true;
    widget.onGeometryChanged(widget.geometry
        .scrolledBy(delta, viewportWidthPx: _viewportWidth));
  }
}
