import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/theme/app_colors.dart';
import '../../core/analysis/audio_extractor.dart';
import '../../core/editing/segmentation_edit_ops.dart';
import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/playback/media_kit_playback.dart';
import '../../core/playback/noop_playback_controller.dart';
import '../../core/playback/playback_controller.dart';
import '../tasks/task_list_controller.dart';
import 'inspector_panel.dart';
import 'player_panel.dart';
import 'timeline/timeline_geometry.dart';
import 'timeline/timeline_view.dart';
import 'timeline_media_builder.dart';
import 'unit_list_panel.dart';
import 'workbench_chrome.dart';

/// 审片台阶段一页面：三栏（单元列表/播放器/检查器）+ 时间线 + 顶栏/底部栏组装
///
/// 装配决策：
/// - [playbackFactory] 缺省时构造真实 `MediaKitPlaybackController`；测试注入
///   [FakePlaybackController]，避免单测触碰 libmpv。
/// - [mediaBuilder] 缺省时构造真实 [TimelineMediaBuilder]（真实 ffmpeg 抽帧/波形），
///   工作目录复用与 `AnalysisPipeline` 一致的 `ishkafel_data/analysis_work`；
///   测试注入假 builder 时改用一次性临时目录（不复用生产缓存位置），避免测试
///   之间因缓存文件互相污染。
/// - `task.units == null || task.videoInfo == null` 时不组装编辑器/播放器，
///   仅渲染错误占位（路由层已按状态拦截，这里是纵深防御，防止极端脏数据崩溃）。
class WorkbenchPage extends ConsumerStatefulWidget {
  final RenewTask task;
  final PlaybackController Function()? playbackFactory;
  final TimelineMediaBuilder? mediaBuilder;

  const WorkbenchPage({
    super.key,
    required this.task,
    this.playbackFactory,
    this.mediaBuilder,
  });

  @override
  ConsumerState<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends ConsumerState<WorkbenchPage> {
  SegmentationEditorController? _editor;
  PlaybackController? _playback;
  Widget? _videoWidget;
  TimelineMedia? _media;
  TimelineGeometry? _geometry;
  StreamSubscription<int>? _positionSub;

  int _playheadMs = 0;
  double _zoomLevel = 1.0;
  double _timelineViewportWidth = 0;

  /// 本次会话是否已通过「确认切分」成功保存；true 时返回不再弹草稿确认框
  bool _confirmed = false;

  bool get _isEditable => widget.task.status == RenewTaskStatus.awaitingCut;

  bool get _needsLeaveConfirm =>
      _editor != null && _editor!.dirty && !_confirmed;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    final units = task.units;
    final videoInfo = task.videoInfo;
    if (units == null || videoInfo == null) {
      return; // 兜底：路由层已拦截，此处只防御极端脏数据
    }

    final editor = SegmentationEditorController(
      initialUnits: units,
      durationMs: videoInfo.duration.inMilliseconds,
      fps: videoInfo.fps,
      sentences: task.asrSentences ?? const [],
    );
    editor.addListener(_onEditorChanged);
    _editor = editor;

    final playback = (widget.playbackFactory ?? _createDefaultPlayback)();
    _playback = playback;
    if (playback is MediaKitPlaybackController) {
      _videoWidget = playback.buildVideoWidget();
    }
    _positionSub = playback.positionMsStream.listen((ms) {
      if (!mounted) return;
      setState(() => _playheadMs = ms);
    });
    unawaited(playback.open(task.sourcePath));
    unawaited(_loadMedia());
  }

  /// 生产环境默认播放后端：真实 `MediaKitPlaybackController`。
  ///
  /// media_kit 要求先在 `main()` 里调用过 `MediaKit.ensureInitialized()`
  /// 才能构造 `Player()`；正常启动流程必然满足。这里仍用 try/catch 兜底
  /// （而不是让整页崩溃）——万一某台机器缺 libmpv 动态库，审片台退化为
  /// 无播放模式（画面占位、切分编辑与确认流转照常可用），比白屏崩溃更好。
  PlaybackController _createDefaultPlayback() {
    try {
      return MediaKitPlaybackController();
    } catch (e) {
      AppLog.warn('播放器初始化失败，审片台将以无播放模式运行：$e');
      return NoopPlaybackController();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _editor?.removeListener(_onEditorChanged);
    unawaited(_playback?.dispose());
    super.dispose();
  }

  void _onEditorChanged() => setState(() {});

  /// 解析媒体构建器与其工作目录：注入假 builder（测试）时用一次性临时目录，
  /// 缺省（生产）时用真实 builder + 与分析管线一致的持久化目录（便于复用缓存）
  Future<({TimelineMediaBuilder builder, Directory workDir})> _resolveMedia() async {
    final injected = widget.mediaBuilder;
    if (injected != null) {
      return (
        builder: injected,
        workDir: Directory.systemTemp.createTempSync('ishkafel_wb_'),
      );
    }
    final supportDir = await getApplicationSupportDirectory();
    final workDir =
        Directory(p.join(supportDir.path, 'ishkafel_data', 'analysis_work'));
    return (
      builder: TimelineMediaBuilder(
          thumbnails: ThumbnailService(), audio: AudioExtractor()),
      workDir: workDir,
    );
  }

  Future<void> _loadMedia() async {
    final videoInfo = widget.task.videoInfo;
    if (videoInfo == null) return;
    try {
      final resolved = await _resolveMedia();
      final media = await resolved.builder.build(
        videoPath: widget.task.sourcePath,
        taskId: widget.task.id,
        durationMs: videoInfo.duration.inMilliseconds,
        workDir: resolved.workDir,
      );
      if (!mounted) return;
      setState(() => _media = media);
    } catch (e) {
      AppLog.warn('时间线媒体加载失败（taskId=${widget.task.id}）：$e');
    }
  }

  Future<void> _onConfirm() async {
    final editor = _editor;
    if (editor == null) return;
    final valid = SegmentationEditOps.holdsInvariants(
        editor.units, editor.durationMs, editor.fps);
    if (!valid) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('切分结构不合法，无法确认（存在越界或过短的边界）')));
      return;
    }
    await ref
        .read(taskListProvider.notifier)
        .confirmSegmentation(widget.task, editor.units);
    _confirmed = true;
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _handleBackRequest() async {
    if (!_needsLeaveConfirm) {
      Navigator.of(context).maybePop();
      return;
    }
    final action = await showLeaveConfirmDialog(context);
    if (action == null || action == LeaveAction.cancel) return;
    if (action == LeaveAction.saveDraft) {
      await ref
          .read(taskListProvider.notifier)
          .saveSegmentationDraft(widget.task, _editor!.units);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _onZoomChanged(double value) {
    final geometry = _geometry;
    if (geometry == null || _timelineViewportWidth <= 0) return;
    final factor = value / _zoomLevel;
    setState(() {
      _zoomLevel = value;
      _geometry = geometry.zoomAt(_timelineViewportWidth / 2, factor,
          viewportWidthPx: _timelineViewportWidth);
    });
  }

  String _summaryText(SegmentationEditorController editor) {
    final units = editor.units;
    final totalShots = units.fold<int>(0, (sum, u) => sum + u.shots.length);
    final durationSec = (editor.durationMs / 1000).toStringAsFixed(1);
    final dirtyHint = editor.dirty ? ' · 有未保存的修改' : '';
    return '共 ${units.length} 个语义单元 · $totalShots 个镜头 · 时长 $durationSec' 's$dirtyHint';
  }

  @override
  Widget build(BuildContext context) {
    final editor = _editor;
    final playback = _playback;
    if (editor == null || playback == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          title: Text(widget.task.name),
        ),
        body: const Center(
          child: Text('该任务尚未完成分析切分，暂时无法进入审片台',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
      );
    }

    return PopScope(
      canPop: !_needsLeaveConfirm,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_handleBackRequest());
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: WorkbenchTopBar(task: widget.task, onBack: _handleBackRequest),
        body: Column(
          children: [
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  SizedBox(
                    width: 320,
                    child: UnitListPanel(
                      controller: editor,
                      onUnitTap: (unit) => playback.seekMs(unit.startMs),
                    ),
                  ),
                  const VerticalDivider(width: 1, color: AppColors.border),
                  Expanded(
                    child: PlayerPanel(
                      playback: playback,
                      videoWidget: _videoWidget,
                      durationMs: editor.durationMs,
                      fps: editor.fps,
                    ),
                  ),
                  const VerticalDivider(width: 1, color: AppColors.border),
                  SizedBox(
                    width: 300,
                    child: InspectorPanel(
                      controller: editor,
                      fps: editor.fps,
                      onSplitAtPlayhead: () =>
                          editor.splitSelectedAt(playback.positionMs),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              flex: 2,
              child: _buildTimelineArea(editor, playback),
            ),
          ],
        ),
        bottomNavigationBar: WorkbenchBottomBar(
          summaryText: _summaryText(editor),
          confirmed: !_isEditable,
          onConfirm: _onConfirm,
        ),
      ),
    );
  }

  Widget _buildTimelineArea(
      SegmentationEditorController editor, PlaybackController playback) {
    return Container(
      color: AppColors.surface,
      child: Column(
        children: [
          _buildTimelineToolbar(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _timelineViewportWidth = constraints.maxWidth;
                _geometry ??= TimelineGeometry.fit(
                    durationMs: editor.durationMs,
                    viewportWidthPx: constraints.maxWidth);
                return TimelineView(
                  controller: editor,
                  geometry: _geometry!,
                  media: _media,
                  playheadMs: _playheadMs,
                  onSeek: (ms) => playback.seekMs(ms),
                  onGeometryChanged: (g) => setState(() => _geometry = g),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineToolbar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          const Icon(Icons.zoom_out, color: AppColors.textTertiary, size: 16),
          Expanded(
            child: Slider(
              key: const Key('timeline-zoom-slider'),
              value: _zoomLevel,
              min: 1,
              max: 20,
              onChanged: _onZoomChanged,
            ),
          ),
          const Icon(Icons.zoom_in, color: AppColors.textTertiary, size: 16),
        ],
      ),
    );
  }
}
