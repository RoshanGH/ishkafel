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
import 'timeline_media_builder.dart';
import 'workbench_body.dart';
import 'workbench_chrome.dart';

/// 审片台阶段一页面：三栏（单元列表/播放器/检查器）+ 时间线 + 顶栏/底部栏组装
///
/// 装配决策：
/// - [playbackFactory] 缺省时构造真实 `MediaKitPlaybackController`；测试注入
///   [FakePlaybackController]，避免单测触碰 libmpv。构造过程若抛出
///   **`Exception`**（生产环境理论上不会——`main.dart` 已在 `runApp` 前
///   调用 `MediaKit.ensureInitialized()`；但万一某台机器缺/坏 libmpv 动态
///   库，或测试刻意注入一个会抛错的工厂），会被捕获并降级为
///   [NoopPlaybackController]，同时置顶一条**用户可见**的橙色提示条
///   （见 [_playbackDegraded]），而不是静默显示占位图标却毫无说明；`Error`
///   子类（编程错误，如 `ArgumentError`/`StateError`）不在捕获范围内，会
///   继续抛出，不被这里误吞。
/// - [mediaBuilder] 缺省时构造真实 [TimelineMediaBuilder]（真实 ffmpeg 抽帧/波形），
///   工作目录复用与 `AnalysisPipeline` 一致的 `ishkafel_data/analysis_work`；
///   测试注入假 builder 时改用一次性临时目录（不复用生产缓存位置），避免测试
///   之间因缓存文件互相污染。
/// - `task.units == null || task.videoInfo == null` 时不组装编辑器/播放器，
///   仅渲染错误占位（路由层已按状态拦截，这里是纵深防御，防止极端脏数据崩溃）。
/// - 三栏 + 时间线的实际布局、页面级全局播放快捷键（空格/←/→）都下沉到
///   [WorkbenchBody]（独立 StatefulWidget，见该文件文档）；本类只负责装配
///   编辑器/播放器/媒体这几项跨区域共享的状态，以及顶栏/底部栏/确认流转/
///   离开确认这些与"三栏内部展示细节"无关的页面级职责。
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
  StreamSubscription<int>? _positionSub;

  int _playheadMs = 0;

  /// 本次会话是否已通过「确认切分」成功保存；true 时返回不再弹草稿确认框
  bool _confirmed = false;

  /// 播放后端是否已降级为 [NoopPlaybackController]（构造真实播放器失败）；
  /// true 时页面顶部常驻一条用户可见的提示条，而不是静默显示占位图标
  bool _playbackDegraded = false;

  bool get _isEditable => widget.task.status == RenewTaskStatus.awaitingCut;

  /// 只读回看模式（picking/exported）下没有 dirty 可言——所有会改数据的
  /// 手势/输入在 [WorkbenchBody] 内已被禁用，直接允许返回，不弹「保存
  /// 草稿」确认框（评审 Important 1）。
  bool get _needsLeaveConfirm =>
      _isEditable && _editor != null && _editor!.dirty && !_confirmed;

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

    final playback = _resolvePlayback();
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

  /// 解析播放后端：优先用测试/调用方注入的 [WorkbenchPage.playbackFactory]，
  /// 缺省时构造真实 `MediaKitPlaybackController`。
  ///
  /// media_kit 要求先在 `main()` 里调用过 `MediaKit.ensureInitialized()`
  /// 才能构造 `Player()`；正常启动流程必然满足，这条 catch 分支在真实 app
  /// 里理论上不会触达。只捕获 `Exception`（`on Exception catch (e)`），不
  /// 捕获 `Error`：media_kit 的 `NativeLibrary.path` 在未 ensureInitialized
  /// 时抛的正是裸 `Exception(...)`（libmpv 缺失/损坏等真机原生故障同理会
  /// 抛 `Exception`，仍会走到这里正常降级+提示），而 `ArgumentError`/
  /// `StateError`/`TypeError`/`AssertionError` 等 `Error` 子类通常意味着
  /// 编程错误——不应被这里静默吞掉、包装成一句"播放器不可用"，而应该继续
  /// 抛出、暴露真正的 bug。只要落入这条 catch，都必须置位
  /// [_playbackDegraded]，在页面上给用户一条可见提示（而不是静默显示占位
  /// 图标却不说明原因），并保留原始异常到日志（按消息文本对已知的"未
  /// 初始化"情形单独给出更精确的措辞）。
  PlaybackController _resolvePlayback() {
    final factory = widget.playbackFactory ?? MediaKitPlaybackController.new;
    try {
      return factory();
    } on Exception catch (e) {
      final looksLikeInitOrderIssue = e.toString().contains('ensureInitialized');
      AppLog.warn(looksLikeInitOrderIssue
          ? '播放器未完成 MediaKit.ensureInitialized 初始化，审片台将以无播放模式运行：$e'
          : '播放器初始化出现未预期异常，审片台将以无播放模式运行：$e');
      _playbackDegraded = true;
      return NoopPlaybackController();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _editor?.removeListener(_onEditorChanged);
    _editor?.dispose();
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
    // 弹窗期间 State 可能已被卸载（如用户经其他途径离开）；在触碰
    // ref/context 之前先检查，避免对已 dispose 的 State 取用 ref
    if (!mounted) return;
    if (action == null || action == LeaveAction.cancel) return;
    if (action == LeaveAction.saveDraft) {
      await ref
          .read(taskListProvider.notifier)
          .saveSegmentationDraft(widget.task, _editor!.units);
      if (!mounted) return;
    }
    Navigator.of(context).pop();
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
            if (_playbackDegraded) const PlaybackDegradedBanner(),
            Expanded(
              child: WorkbenchBody(
                editor: editor,
                playback: playback,
                videoWidget: _videoWidget,
                media: _media,
                playheadMs: _playheadMs,
                readOnly: !_isEditable,
              ),
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
}
