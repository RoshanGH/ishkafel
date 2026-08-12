import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/theme/app_colors.dart';
import '../../core/analysis/audio_extractor.dart';
import '../../core/editing/edit_locks.dart';
import '../../core/editing/blank_unit_ops.dart';
import '../../core/editing/blank_unit_removal.dart';
import '../blank_task/blank_unit_tag_editor.dart';
import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/ai/ai_usage_scope.dart';
import '../../core/audio/voice_swap_service.dart';
import '../../core/log/app_log.dart';
import '../../core/models/export_record.dart';
import '../../core/models/renew_task.dart';
import '../../core/net/http_bytes.dart';
import '../../core/miaoa/candidate_probe.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/playback/media_kit_playback.dart';
import '../../core/playback/noop_playback_controller.dart';
import '../../core/playback/playback_controller.dart';
import '../../core/ffmpeg/ffprobe_service.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/proxy_builder.dart';
import '../../core/ffmpeg/proxy_spec.dart';
import '../../core/ffmpeg/rendered_cache.dart';
import '../../core/playback/media_kit_follower.dart';
import '../../core/playback/multitrack_playback.dart';
import 'preview_tracks.dart';
import 'speed_fitter.dart';

import '../../core/replacement/picked_material.dart';
import '../../core/replacement/replacement_plan.dart';
import '../../core/editing/edit_consequence.dart';
import '../picking/picking_messages.dart';
import '../settings/settings_providers.dart';
import '../tasks/task_list_controller.dart';
import '../../core/audio/audio_preview.dart';
import '../../core/audio/bgm_plan.dart';
import 'bgm_picker_sheet.dart';
import 'candidate_badge.dart';
import 'voice_picker_sheet.dart';
import 'voice_swap_runner.dart';
import 'timeline/bgm_track.dart';
import 'candidate_tab.dart';
import '../picking/picked_material_store.dart';
import '../picking/picked_media_cache.dart';
import '../picking/picking_providers.dart';
import 'edit_consequence_dialog.dart';
import 'task_tag_groups_dialog.dart';
import 'timeline/timeline_painter.dart';
import 'timeline_media_builder.dart';
import 'workbench_body.dart';
import 'workbench_chrome.dart';
import 'workbench_summary.dart';
import '../export/export_dialog.dart';
import '../../core/storage/task_lock.dart';
import 'task_lock_banner.dart';

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
/// - `task.units == null`（或非空白任务而 `videoInfo == null`）时不组装
///   编辑器/播放器，
///   仅渲染错误占位（路由层已按状态拦截，这里是纵深防御，防止极端脏数据崩溃）。
/// - 三栏 + 时间线的实际布局、页面级全局播放快捷键（空格/←/→）都下沉到
///   [WorkbenchBody]（独立 StatefulWidget，见该文件文档）；本类只负责装配
///   编辑器/播放器/媒体这几项跨区域共享的状态，以及顶栏/底部栏/确认流转/
///   离开确认这些与"三栏内部展示细节"无关的页面级职责。
class WorkbenchPage extends ConsumerStatefulWidget {
  final RenewTask task;
  final PlaybackController Function()? playbackFactory;
  final TimelineMediaBuilder? mediaBuilder;

  /// 时间线判定双击用的时钟。默认真实时间；测试注入可控时钟，否则机器一忙
  /// 两次点击的间隔就超过双击窗口，用例随机变红。
  final DateTime Function()? clock;

  /// 右栏「替换素材」的依赖，缺省走真实 miaoa CLI；测试注入假实现
  /// 把挑中的素材落到盘上（下首帧图）。为空表示不落地——托盘仍然能画，
  /// 只是重开 app 之后要现拉
  final PickedMaterialStore? pickedStore;

  final MiaoaContentService? contentService;
  final CandidateProbe? candidateProbe;
  final MiaoaTagService? tagService;

  /// 「生成配音」的装配点。缺省读 [voiceSwapFactoryProvider]（凭据齐才有）；
  /// 测试注入假实现，避免单测真去跑云端合成。
  final VoiceSwapFactory? voiceSwapFactory;

  /// 试听配音用的播放器。缺省懒创建真实的；测试注入假实现，
  /// 免得单测去碰 libmpv。
  final AudioPreview? audioPreview;

  const WorkbenchPage({
    super.key,
    required this.task,
    this.playbackFactory,
    this.mediaBuilder,
    this.clock,
    this.pickedStore,
    this.contentService,
    this.candidateProbe,
    this.tagService,
    this.voiceSwapFactory,
    this.audioPreview,
  });

  @override
  ConsumerState<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends ConsumerState<WorkbenchPage> {
  SegmentationEditorController? _editor;
  PlaybackController? _playback;
  Widget? _videoWidget;
  TimelineMedia? _media;

  /// 抽帧/波形是否构建失败。与 `_media == null` 一起决定时间线两条辅助轨
  /// 显示「生成中…」还是「生成失败」——此前失败只写日志，界面上是一片
  /// 空白，用户无从判断是在算还是坏了。
  bool _mediaFailed = false;
  StreamSubscription<int>? _positionSub;

  /// 播放位置。用 [ValueNotifier] 而不是 State 字段：播放时这个值每秒变化
  /// 30 次，而它唯一的消费者是时间线上那条 2px 的播放头线。若走 `setState`，
  /// 每次 tick 都会连带重建左栏单元列表、播放器、右栏检查器与底部栏——
  /// 实测每 tick 净开销 10~12ms，占满 60fps 预算的七成，播放与拖拽因此发顿。
  final ValueNotifier<int> _playhead = ValueNotifier<int>(0);

  /// 留着引用只为离开时 [SpeedFitter.prune] 一次
  SpeedFitter? _speedFitter;

  /// 别人（多半是 Agent）持有的锁；为 null 表示没人占着
  TaskLock? _lock;
  Timer? _lockTimer;

  /// 锁文件。**在 initState 里就存下来**：dispose 时要放锁，而那时候
  /// 已经不能再碰 ref（Riverpod 会抛 "Cannot use ref after disposed"）
  TaskLockFile? _lockFile;

  /// 本进程的身份。横幅上要能说出是谁占着，所以带上 pid
  String get _lockHolder => 'gui:$pid';

  /// 占住锁并盯着它。
  ///
  /// **进工作台就占锁**：人正在编辑而 Agent 同时在写，后写的会把先写的覆盖
  /// 掉。两个方向都要防，不能只防 Agent 那一边。
  ///
  /// 每 5 秒一轮：既给自己的锁续命，也看看是不是被别人抢了。这个间隔比 60 秒
  /// 的失效阈值密得多——对方一结束或一崩掉，很快就能恢复可编辑，而不是让人
  /// 干等一分钟；自己这把锁也不会因为一次卡顿就过期。
  void _watchLock() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final file = TaskLockFile(dataDir: dataDir, taskId: widget.task.id);
    _lockFile = file;

    void poll() {
      // 先试着占住/续命。占不到说明别人正持着，那就进只读
      final mine = file.heartbeat(_lockHolder) || file.acquire(_lockHolder);
      final current = mine ? null : file.read();
      final held = current != null &&
          current.holder != _lockHolder &&
          !current.isStale(DateTime.now().toUtc());
      final next = held ? current : null;
      if (next?.holder == _lock?.holder) return;
      if (mounted) setState(() => _lock = next);
    }

    poll();
    _lockTimer = Timer.periodic(const Duration(seconds: 5), (_) => poll());
  }

  /// 离开工作台就放锁——不放的话，别人要等 60 秒超时才能接手
  void _releaseLock() => _lockFile?.release(_lockHolder);

  void _takeoverLock() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    TaskLockFile(dataDir: dataDir, taskId: widget.task.id)
        .forceTakeover(_lockHolder);
    setState(() => _lock = null);
  }

  /// 上一次向 UI 反映的 dirty 值。编辑器每次 notify 都会走 [_onEditorChanged]，
  /// 但页面本身只有 [PopScope.canPop] 依赖 dirty，只在它真正翻转时才需要重建。
  bool _lastDirty = false;

  /// 自动落库的防抖计时器。拖一次边界会触发几十次编辑，逐次写盘既浪费
  /// 又会在连续拖动时排成一长串写入。
  Timer? _autosaveTimer;

  /// 最近一次已落库的 units。真的变了才写——undo 回到原样、或只是切换选中，
  /// 都不该产生一次写盘。
  List<SemanticUnit>? _savedUnits;

  /// 当前替换方案。右栏改一次就落库一次，与切分改动同一条自动保存通路。
  List<UnitReplacement>? _replacements;

  /// 「改完之后要不要连坐」的询问计时器与结算基线。基线是上一次结算时的
  /// units：只问这之后的新改动，否则用户每改一次都会被翻旧账。
  Timer? _consequenceTimer;
  List<SemanticUnit>? _consequenceBaseline;
  bool _askingConsequence = false;

  /// 正在重新打标。要走两趟云端推理，几秒到几十秒，界面上必须有个说法，
  /// 否则用户会以为点了「是」什么都没发生。
  int _retaggingCount = 0;

  /// 配音生成进度。每句要走一次音频理解 + 一到两次合成，十句就是一分多钟，
  /// 没有进度用户只会以为卡死了。
  (int done, int total)? _voiceProgress;

  /// 已经生成好的配音文件，按台词语义单元下标。有文件才给试听按钮——
  /// 给一个点了没声音的按钮比不给还糟。
  Map<int, String> _voiceAudio = const {};

  /// 试听用的独立播放器：时间线那个正播着原片，不能把它的位置弄丢
  AudioPreview? _preview;

  /// 预览音轨：让工作台里听到的就是导出后的声音（配音替换 + 配乐叠加）
  PreviewTracks? _tracks;

  /// 任务列表控制器。在 initState 里就抓住：dispose 时 `ref` 已经失效，
  /// 而离开页面时那次补写恰恰发生在 dispose 里。
  TaskListController? _tasks;

  /// 这条任务的最新状态。
  ///
  /// **不能拿 `widget.task` 去存**：切分和替换方案走两条落库通路，两边都
  /// 从同一个进页面时的旧快照 copyWith，后写的那次就会把前一次的改动整个
  /// 盖回去——清掉素材再标记重打，素材又活过来了。
  late RenewTask _task = widget.task;

  /// 播放后端是否已降级为 [NoopPlaybackController]（构造真实播放器失败）；
  /// true 时页面顶部常驻一条用户可见的提示条，而不是静默显示占位图标
  bool _playbackDegraded = false;

  /// 项目**永远可编辑**。
  ///
  /// 一条原片放在那儿反复出不同组合：今天挑两个导出去，明天换两个再导。
  /// 没有「导完就锁住」这回事——那个 `exported` 状态从来没有一处代码把它
  /// 设上过，只读回看整套逻辑一直是死的。
  bool get _isEditable => true;

  @override
  void initState() {
    super.initState();
    _tasks = ref.read(taskListProvider.notifier);
    _mediaCache = _buildMediaCache();
    _bgmMediaCache = _buildBgmMediaCache()?..addListener(_onMediaCacheChanged);
    _mediaCache?.addListener(_onMediaCacheChanged);
    final task = widget.task;
    final units = task.units;
    final videoInfo = task.videoInfo;
    // 空白任务没有原片，也就没有 videoInfo。它进的是同一个工作台——
    // 时间线、配乐、矩阵导出这些能力跟有没有原片无关，另起一页会把它们全丢掉
    if (units == null || (videoInfo == null && !task.isBlank)) {
      return; // 兜底：路由层已拦截，此处只防御极端脏数据
    }

    final editor = SegmentationEditorController(
      initialUnits: units,
      // 空白任务的总长由分子加出来（没挑素材的按占位长度算）
      durationMs: videoInfo?.duration.inMilliseconds ??
          (units.isEmpty ? BlankUnitOps.placeholderMs : units.last.endMs),
      // 没有原片就没有原片帧率。30 只是内部坐标的刻度——成片规格跟素材走
      fps: videoInfo?.fps ?? 30,
      sentences: task.asrSentences ?? const [],
    );
    editor.addListener(_onEditorChanged);
    _editor = editor;
    _replacements = task.replacements;
    _syncEditLocks();
    _pinMaterials();
    _consequenceBaseline = units;
    // 进工作台就把方案里的配乐固定住——只在「选完」时才下的话，
    // 打开一条早就配好乐的任务什么都不会发生
    _pinBgm();
    // 素材已经在本地、但落地记录里缺时长的，补一次（整体替换靠它算长度）
    unawaited(_backfillDurations());

    final playback = _resolvePlayback();
    _playback = playback;
    _videoWidget = switch (playback) {
      MultitrackPlayback() => playback.buildVideoWidget(),
      MediaKitPlaybackController() => playback.buildVideoWidget(),
      _ => null,
    };
    // 只更新 notifier，不触发页面重建；重复值直接丢弃（mpv 会重复上报同一毫秒）
    _positionSub = playback.positionMsStream.listen((ms) {
      if (!mounted) return;
      // 预览播的可能是**合成出来的成片**（整体替换会改变时长），而时间线画的
      // 是原片切分——播放头要换算回原片时刻，否则整体替换之后指针就飘了
      // 时间线现在画的就是成片，播放头直接用播放器位置——不必再换算回
      // 原片时刻（那一步在整体替换段上是按比例估的，本来就不精确）
      if (_playhead.value == ms) return;
      _playhead.value = ms;
    });
    // 空白任务没有原片可开。画面全部来自素材，等轨道推上去自然就有内容了
    if (task.sourcePath case final source?) {
      unawaited(_openSource(playback, source));
    }
    unawaited(_loadMedia());
    _restoreVoiceAudio();

    if (playback is MultitrackPlayback) {
      _tracks = PreviewTracks(
        playback: playback,
        materials: _mediaCache,
        bgmMedia: _bgmMediaCache,
        speedFitter: _speedFitter = _buildSpeedFitter(),
      )
        ..addListener(_onTracksChanged)
        ..onNeedsRebuild = _syncPreviewAudio;
      // 后台转原片代理，转好了自动换上；这期间先播原片
      unawaited(_buildSourceProxy());
    }
    _syncPreviewAudio();
    _watchLock();
  }

  /// 变速切片的渲染器。没有数据目录（测试环境）就不做变速——
  /// 那一段先播原片，其余照旧
  SpeedFitter? _buildSpeedFitter() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return null;
    return SpeedFitter(
      cache: RenderedCache(
        dir: Directory(p.join(dataDir.path, 'speed_fit', widget.task.id)),
        run: const ResolvingProcessRunner().call,
      ),
      probeDurationMs: (path) async =>
          (await FfprobeService(run: const ResolvingProcessRunner().call)
                  .probe(path))
              .duration
              .inMilliseconds,
      // 切片也编成代理规格：预览链路上每一段规格一致，接缝处才不用重建解码器
      targetSpec: () async => ProxySpec.at(_frameRateArg),
    );
  }

  /// 三条轨：画面（主时钟，静音）+ 口播 + 配乐（循环）
  static PlaybackController _multitrack() => MultitrackPlayback(
        video: MediaKitPlaybackController(),
        voice: MediaKitFollower(),
        bgm: MediaKitFollower(loop: true),
      );

  void _onTracksChanged() {
    if (mounted) setState(() {});
  }

  /// 方案变了就重推轨道。与画面/声音无关的改动会被轨道指纹挡掉。
  void _syncPreviewAudio() {
    final editor = _editor;
    if (editor == null) return;
    unawaited(_tracks?.update(
      task: _task,
      units: editor.units,
      voiceAudio: _voiceAudio,
      // 各槽位取标了 ★ 的那个候选
      replacements: _replacements ?? const [],
    ));
  }

  /// 打开原片。失败要让用户看见——文件被移走/改名时，静默失败的表现是
  /// 「点了播放没反应」，用户无从判断是坏了还是没加载完。
  Future<void> _openSource(PlaybackController playback, String path) async {
    try {
      await playback.open(path);
    } catch (e) {
      AppLog.warn('打开原片失败（$path）：$e');
      if (mounted) setState(() => _playbackDegraded = true);
    }
  }

  /// 重开页面时恢复「哪几句已经配好音了」。
  ///
  /// 不恢复的话，用户昨天生成过的配音今天点不到试听，只会以为白跑了一轮。
  void _restoreVoiceAudio() {
    final factory = widget.voiceSwapFactory ?? ref.read(voiceSwapFactoryProvider);
    if (factory == null) return;
    try {
      _voiceAudio = factory(widget.task)
              ?.existingAudio(widget.task.voices.assignedUnits) ??
          const {};
    } catch (e) {
      // 目录读不出来只影响试听按钮，不该拦住整个页面
      AppLog.warn('恢复已生成配音失败（taskId=${widget.task.id}）：$e');
    }
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
    // 缺省是**三条独立轨**：画面主时钟 + 口播 + 配乐（见 [MultitrackPlayback]）。
    // 测试注入 FakePlaybackController，不碰 libmpv
    final factory = widget.playbackFactory ?? _multitrack;
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
    _lockTimer?.cancel();
    _releaseLock();
    _consequenceTimer?.cancel();
    _flushAutosaveOnDispose();
    _positionSub?.cancel();
    _editor?.removeListener(_onEditorChanged);
    _editor?.dispose();
    _playhead.dispose();
    unawaited(_playback?.dispose());
    unawaited(_preview?.dispose());
    _tracks?.removeListener(_onTracksChanged);
    _tracks?.dispose();
    // 变速切片也要回收：只留这一次方案还在用的那几段。
    // 此前 prune 压根没人调，真机上 speed_fit 里堆了 6 个切片、4 个早就废了
    _speedFitter?.prune();
    // 离开工作台时做一次配额回收：固定住的一律不动，只淘汰没人用的
    for (final cache in [_mediaCache, _bgmMediaCache]) {
      if (cache == null) continue;
      cache.removeListener(_onMediaCacheChanged);
      cache.sweep();
      cache.dispose();
    }
    super.dispose();
  }

  /// 页面销毁时把还压在防抖窗口里的那次改动补写掉。
  ///
  /// 两件事都要做：定时器必须取消（否则它会在页面没了之后开火，拿着一个已经
  /// 失效的 ref 去写盘），而它本来要写的那次改动也不能就这么丢——用户刚拖完
  /// 边界就关窗口，改动理应已经留住。写盘走 [_tasks]（initState 里就抓住的
  /// notifier）——dispose 里 `ref` 已经失效，用它取会直接抛 StateError。
  void _flushAutosaveOnDispose() {
    final pending = _autosaveTimer?.isActive ?? false;
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    final editor = _editor;
    if (!pending || editor == null || !_isEditable) return;
    final units = editor.units;
    if (_savedUnits != null &&
        const ListEquality<SemanticUnit>().equals(_savedUnits!, units)) {
      return;
    }
    final notifier = _tasks;
    if (notifier == null) return;
    unawaited(() async {
      try {
        await notifier.saveSegmentationDraft(_task, units);
      } catch (e) {
        // 页面已经没了，弹不出提示，只能进日志
        AppLog.warn('离开时的自动保存失败（taskId=${widget.task.id}）：$e');
      }
    }());
  }

  /// 时间线辅助素材的就绪状态
  TimelineMediaStatus get _mediaStatus {
    // 空白任务没有原片，缩略图和波形永远不会有——显示「生成中…」等于挂一个
    // 永远转下去的圈
    if (_task.isBlank) return TimelineMediaStatus.noSource;
    if (_media != null) return TimelineMediaStatus.ready;
    return _mediaFailed
        ? TimelineMediaStatus.failed
        : TimelineMediaStatus.loading;
  }

  /// 编辑器变化时**只在 dirty 真正翻转时**重建页面。
  ///
  /// 页面本身唯一依赖编辑器状态的地方是 [PopScope.canPop]（决定返回时是否
  /// 弹「保存草稿」确认框）；三栏面板与底部栏各自监听同一个 controller，
  /// 不需要页面代劳。改造前这里无条件 `setState`，于是拖拽边界时每个
  /// DragUpdate（macOS 触控板约 90~125Hz）都重建整页。
  /// 空白任务：在末尾加一个空分子。
  ///
  /// 走 [SegmentationEditorController.replaceUnitsForBlankTask] 而不是切分
  /// 那套操作——那套要保证「无缝覆盖固定的原片时长」，而这里总长本来就是
  /// 加出来的。
  void _addBlankUnit() {
    final editor = _editor;
    if (editor == null || !_isEditable || _lock != null) return;
    final next = BlankUnitOps.append(editor.units);
    editor.replaceUnitsForBlankTask(next, next.last.endMs);
    editor.select(EditorSelection.unit(next.length - 1));
    _scheduleAutosave();
  }

  /// 空白任务的分子标签编辑器。只能从任务标签组的词表里选——手打的标签
  /// 检索时一个都命中不了，而用户打完字看不出任何异常
  Widget _blankTagEditor(int unitIndex, List<String> tags) =>
      BlankUnitTagEditor(
        key: ValueKey('blank-tags-$unitIndex'),
        unitIndex: unitIndex,
        tags: tags,
        tagGroups: _task.unitTagGroups,
        project: _task.project,
        onChanged: (next) {
          final editor = _editor;
          if (editor == null || !_isEditable || _lock != null) return;
          final units = BlankUnitOps.setTags(editor.units, unitIndex, next);
          editor.replaceUnitsForBlankTask(
              units, units.isEmpty ? BlankUnitOps.placeholderMs : units.last.endMs);
          _scheduleAutosave();
        },
      );

  /// 空白任务：删掉一个分子。
  ///
  /// 分子本身好删，风险在旁边两份**也是按下标记**的数据：替换方案和配乐
  /// 区间。它们不跟着挪不会报错，只会让成片悄悄变成另一个样子
  /// （见 [shiftReplacementsAfterRemoval] / [shiftBgmAfterRemoval]）。
  Future<void> _deleteBlankUnit(int unitIndex) async {
    final editor = _editor;
    if (editor == null || !_isEditable || _lock != null) return;
    if (editor.units.length <= blankMinUnits) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('至少要留 $blankMinUnits 个分子')));
      return;
    }

    final picked = (_replacements ?? const []).length > unitIndex &&
        _replacements![unitIndex].wholeCandidateIds.isNotEmpty;
    if (picked) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('删掉 U${unitIndex + 1}？'),
          content: const Text('它已经挑好素材了。删掉之后这个选择也一并没了，撤不回来。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删掉')),
          ],
        ),
      );
      if (ok != true) return;
    }

    final units = BlankUnitOps.removeAt(editor.units, unitIndex);
    setState(() {
      _replacements = shiftReplacementsAfterRemoval(
          _replacements ?? const [], removed: unitIndex);
      _task = _task.copyWith(
          bgm: shiftBgmAfterRemoval(_task.bgm, removed: unitIndex));
    });
    editor.replaceUnitsForBlankTask(
        units, units.isEmpty ? BlankUnitOps.placeholderMs : units.last.endMs);
    unawaited(_saveBgm(_task.bgm));
    _scheduleAutosave();
  }

  void _onEditorChanged() {
    // 边界动过，每一段的时长就变了，预览音轨要重合（它自己带防抖）
    _syncPreviewAudio();
    _scheduleAutosave();
    _scheduleConsequenceCheck();
    final dirty = _editor?.dirty ?? false;
    if (dirty == _lastDirty) return;
    setState(() => _lastDirty = dirty);
  }

  /// 编辑停下来之后再问「要不要清素材/重打标」。
  ///
  /// 比自动保存等得久得多：用户往往连着拖好几刀才算改完一处，改一下弹一次
  /// 会把人逼疯。3 秒是「手停下来了」的信号。
  void _scheduleConsequenceCheck() {
    _consequenceTimer?.cancel();
    _consequenceTimer = Timer(const Duration(seconds: 3), _askConsequence);
  }

  Future<void> _askConsequence() async {
    _consequenceTimer = null;
    final editor = _editor;
    if (editor == null || !_isEditable || _askingConsequence) return;

    final baseline = _consequenceBaseline ?? widget.task.units ?? const [];
    final consequence = EditConsequence.evaluate(
      before: baseline,
      after: editor.units,
      replacements: _replacements ?? const [],
    );
    // 无论问不问，这一轮都已经结算过了：下次只比这次之后的新改动
    _consequenceBaseline = editor.units;
    if (consequence == null || !mounted) return;

    _askingConsequence = true;
    try {
      final choice = await showEditConsequenceDialog(context, consequence);
      if (choice == null || choice.nothingToDo || !mounted) return;
      if (choice.clearCandidates) {
        await _onReplacementsChanged(
            consequence.clearCandidates(_replacements ?? const []));
      }
      if (choice.retag) await _retag(consequence);
    } finally {
      _askingConsequence = false;
    }
  }

  /// 给若干台词语义单元换音色。
  ///
  /// 只落方案，不立刻合成——合成要走云端、几秒一句，用户往往先把几句都配好
  /// 再统一生成。真正的合成由「生成配音」触发。
  Future<void> _changeVoice(int unitIndex) async {
    final editor = _editor;
    if (editor == null) return;
    final choice = await showVoicePicker(
      context,
      units: editor.units,
      plan: _task.voices,
      focusedUnit: unitIndex,
    );
    if (choice == null || !mounted) return;
    final next = choice.voice == null
        ? _task.voices.clear(choice.unitIndexes)
        : _task.voices.assign(choice.unitIndexes, choice.voice!);
    setState(() => _task = _task.copyWith(voices: next));
    _syncPreviewAudio();
    try {
      await _tasks!.saveVoices(_task, next);
    } catch (e) {
      AppLog.warn('换音色方案落库失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showSaveFailure('配音方案');
    }
  }

  /// 「生成配音」：把已经定好的换音色方案真正跑成音频。
  ///
  /// 与「选音色」分开是刻意的：选音色是即时的，生成要走云端、每句几秒，
  /// 用户往往先把几句都配好再统一生成。
  Future<void> _generateVoices() async {
    final editor = _editor;
    final factory = widget.voiceSwapFactory ?? ref.read(voiceSwapFactoryProvider);
    if (editor == null || _task.voices.isEmpty) return;
    if (factory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务，无法生成配音；补齐凭据后重启应用再试')));
      return;
    }

    final job = factory(_task);
    if (job == null) {
      // 空白任务没有台词可念。这个按钮本来就不该出现在这类任务上，
      // 真出现了也要说人话
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('这条任务没有台词，换不了音色')));
      return;
    }
    setState(() => _voiceProgress = (0, _task.voices.assignedUnits.length));
    try {
      // 合成按字符计费，且用户会反复改台词重生成——记进这个任务的账
      late Map<int, VoiceSwapResult> results;
      final usage = await AiUsageScope.collect(
        () async {
          results = await job.service.run(
            units: editor.units,
            sentences: widget.task.asrSentences ?? const [],
            plan: _task.voices,
            onProgress: (done, total) {
              if (mounted) setState(() => _voiceProgress = (done, total));
            },
          );
        },
        // 中途失败时前面已经合成的照样计费
        onPartial: (partial) =>
            _task = _task.copyWith(aiUsage: _task.aiUsage.merge(partial)),
      );
      _task = _task.copyWith(aiUsage: _task.aiUsage.merge(usage));
      // 落盘：跑一轮要几十秒到几分钟，只留在内存里的话关掉页面就得重跑
      final written = <int, String>{};
      job.outputDir.createSync(recursive: true);
      for (final entry in results.entries) {
        final file = job.audioFor(entry.key)
          ..writeAsBytesSync(entry.value.audio);
        written[entry.key] = file.path;
      }
      if (!mounted) return;
      final failed = job.service.failures;
      setState(() => _voiceAudio = {..._voiceAudio, ...written});
      _syncPreviewAudio();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(failed.isEmpty
            ? '已生成 ${written.length} 句配音，可在检查器里试听'
            // 失败的那几句要点名，用户才知道去重跑哪几句
            : '已生成 ${written.length} 句；'
                '${failed.keys.map((i) => 'U${i + 1}').join('、')} 失败，可再点一次只补这几句'),
        backgroundColor: failed.isEmpty ? null : AppColors.red,
      ));
    } catch (e) {
      AppLog.warn('生成配音失败（taskId=${widget.task.id}）：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('生成配音失败：$e'),
          backgroundColor: AppColors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _voiceProgress = null);
    }
  }

  /// 试听某个单元已生成的配音
  Future<void> _previewVoice(int unitIndex) async {
    final path = _voiceAudio[unitIndex];
    if (path == null) return;
    try {
      await (_preview ??= widget.audioPreview ?? AudioPreview()).play(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('试听失败，音频文件可能已被清理')));
      }
    }
  }

  /// 在配乐轨上框选完一段单元：挑一首铺上去。
  Future<void> _pickBgmForRange(int fromUnit, int toUnit) async {
    final editor = _editor;
    if (editor == null) return;
    final rangeMs = unitRangeMs(editor.units, from: fromUnit, to: toUnit);
    final choice = await showBgmPicker(
      context,
      rangeMs: rangeMs,
      rangeLabel: _unitRangeLabel(fromUnit, toUnit),
      projectIds: _projectIds,
    );
    if (choice is! BgmPicked || !mounted) return;
    await _saveBgm(_task.bgm.assign(
      startUnit: fromUnit,
      endUnit: toUnit,
      materials: choice.materials,
      previewIndex: choice.previewIndex,
      rangeMs: rangeMs,
      volume: choice.volume,
    ));
  }

  static bool _sameGroups(List<TagGroupRef> a, List<TagGroupRef> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 重新推一次轨道。配乐/素材取不到最常见的两个原因是网络抖动和登录过期，
  /// 重试一次多半就好了——而此前用户只能去重新选一遍
  void _retryPreviewAudio() {
    for (final cache in [_mediaCache, _bgmMediaCache]) {
      for (final id in cache?.notReady ?? const <int>[]) {
        cache!.retry(id);
      }
    }
    _syncPreviewAudio();
  }

  /// 拖段落边界改长度。只改长度——曲子、备选、音量、预览版都不动
  Future<void> _resizeBgm(int startUnit, int newStart, int newEnd) =>
      _saveBgm(_task.bgm
          .resize(startUnit: startUnit, newStart: newStart, newEnd: newEnd));

  /// 点段落上的 × 删掉它。此前删一段要点开素材库浮层再点移除，太重
  Future<void> _deleteBgm(int startUnit) =>
      _saveBgm(_task.bgm.removeSegment(startUnit));

  /// 被整体替换的单元在成片里的时长（时间线上要标出「15.3s → 11.3s」）。
  /// 直接从画面轨读——每个整体替换单元就是轨上的一段
  Map<int, int> get _composedDurations {
    final tracks = _tracks;
    if (tracks == null) return const {};
    final units = _editor?.units ?? const [];
    final out = <int, int>{};
    for (var i = 0; i < units.length && i < (_replacements?.length ?? 0); i++) {
      final replacement = _replacements![i];
      if (replacement.mode != ReplacementMode.whole) continue;
      final id = replacement.wholePreviewId;
      final path = id == null ? null : _mediaCache?.localPathOf(id);
      if (path == null) continue;
      for (final segment in tracks.plan.video) {
        if (segment.source == path) {
          out[i] = segment.durationMs;
          break;
        }
      }
    }
    return out;
  }

  /// 传给 miaoa CLI 的 `--projects`；不限项目时为空
  List<int> get _projectIds =>
      _task.project == null ? const [] : [_task.project!.id];

  /// 点了配乐轨上已有的一段：换一首，或者移除
  Future<void> _editBgmSegment(BgmSegment segment) async {
    final editor = _editor;
    if (editor == null) return;
    final rangeMs = unitRangeMs(editor.units,
        from: segment.startUnit, to: segment.endUnit);
    final choice = await showBgmPicker(
      context,
      rangeMs: rangeMs,
      rangeLabel: _unitRangeLabel(segment.startUnit, segment.endUnit),
      canClear: true,
      projectIds: _projectIds,
      initialVolume: segment.volume,
      initialMaterials: segment.materials,
      initialPreviewIndex: segment.previewIndex,
    );
    if (choice == null || !mounted) return;
    await _saveBgm(switch (choice) {
      BgmVolumeChanged(:final volume) => _task.bgm
          .withVolume(startUnit: segment.startUnit, volume: volume),
      BgmPicked(:final materials, :final previewIndex, :final volume) =>
        _task.bgm.assign(
          startUnit: segment.startUnit,
          endUnit: segment.endUnit,
          materials: materials,
          previewIndex: previewIndex,
          rangeMs: rangeMs,
          volume: volume,
        ),
      BgmCleared() => _task.bgm.removeAt(segment.startUnit),
    });
  }

  /// 「U2–U4」这样的区间名。配乐按台词语义单元对齐（见 [BgmSegment.startUnit]）
  String _unitRangeLabel(int from, int to) =>
      from == to ? 'U${from + 1}' : 'U${from + 1}–U${to + 1}';

  Future<void> _saveBgm(BgmPlan next) async {
    setState(() => _task = _task.copyWith(bgm: next));
    // 选中就把曲子下到本地：素材库那边被删也不影响这条任务
    _pinBgm();
    // 配乐变了，预览音轨要跟着重合——否则加完配乐播放还是原声
    _syncPreviewAudio();
    try {
      await _tasks!.saveBgm(_task, next);
    } catch (e) {
      AppLog.warn('配乐方案落库失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showSaveFailure('配乐方案');
    }
  }

  /// 改这条任务用哪些标签组，并按需立刻用新词表重打全片。
  ///
  /// 换了词表却不重打，标签还是按旧词表打的——那份标签既不在新词表里，
  /// 拿去检索素材也一个都对不上。所以这个对话框默认勾着「立即重打」。
  Future<void> _editTagGroups() async {
    final editor = _editor;
    if (editor == null) return;
    final picked = await showTaskTagGroupsDialog(
      context,
      unit: _task.unitTagGroups,
      shot: _task.shotTagGroups,
      unitPrompt: _task.unitTagPrompt,
      shotPrompt: _task.shotTagPrompt,
      project: _task.project,
    );
    if (picked == null || !mounted) return;

    // 打标的输入变没变：词表（标签组）与约束。项目不在其中
    final taggingChanged = !_sameGroups(_task.unitTagGroups, picked.unit) ||
        !_sameGroups(_task.shotTagGroups, picked.shot) ||
        _task.unitTagPrompt != picked.unitPrompt ||
        _task.shotTagPrompt != picked.shotPrompt;

    _task = _task.copyWith(
      unitTagGroups: picked.unit,
      shotTagGroups: picked.shot,
      unitTagPrompt: picked.unitPrompt,
      shotTagPrompt: picked.shotPrompt,
      project: picked.project,
      // 选了「不限项目」要真的清掉
      clearProject: picked.project == null,
    );
    try {
      await _tasks!.saveTagGroups(
        _task,
        unit: picked.unit,
        shot: picked.shot,
        unitPrompt: picked.unitPrompt,
        shotPrompt: picked.shotPrompt,
        project: picked.project,
      );
    } catch (e) {
      AppLog.warn('标签组落库失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showSaveFailure('标签组');
      return;
    }
    if (!mounted) return;
    setState(() {});
    // 只改了项目就别重打：项目决定的是「上哪儿找替换素材」，
    // 跟怎么打标毫无关系，白跑一遍几分钟的云端推理
    if (!picked.retagNow || !taggingChanged) return;

    // 全片重打：换词表就是把整份标签作废了，只重打其中几个没有意义
    await _retag(EditConsequence(
      unitIndexes: [for (var i = 0; i < editor.units.length; i++) i],
      structural: true,
      maxChangedRatio: 1,
    ));
  }

  /// 「立刻去打标」。
  ///
  /// 先把受影响单元标记为待重打并落库，再送去打标：打标要走两趟云端推理，
  /// 中途失败或用户关掉窗口都是常事，标记留在盘上，界面上才看得出这些标签
  /// 已经过期，而不是让人拿着一份对不上画面的标签往下走。
  Future<void> _retag(EditConsequence consequence) async {
    final editor = _editor;
    if (editor == null) return;
    editor.replaceUnits(consequence.markForRetag(editor.units));
    await _flushAutosave();
    if (!mounted) return;

    final tagging = ref.read(taggingServiceProvider);
    if (tagging == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务，已标记为待重打；补齐凭据后可再次重打')));
      return;
    }

    setState(() => _retaggingCount = consequence.unitIndexes.length);
    try {
      // 重打标是「花费不停累积」的主要来源：用户改一次切分就走一趟云端推理，
      // 记账要跟着（见 [AiUsageScope]）
      late List<SemanticUnit> tagged;
      final usage = await AiUsageScope.collect(
        () async {
          tagged = await tagging.tag(_task, editor.units,
              only: consequence.unitIndexes.toSet());
        },
        onPartial: (partial) => _task =
            _task.copyWith(aiUsage: _task.aiUsage.merge(partial)),
      );
      _task = _task.copyWith(aiUsage: _task.aiUsage.merge(usage));
      if (!mounted) return;
      editor.replaceUnits(tagged);
      await _flushAutosave();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已重新打标 ${consequence.unitIndexes.length} 个台词语义单元')));
    } catch (e) {
      AppLog.warn('重新打标失败（taskId=${widget.task.id}）：$e');
      // 失败也要把已经花掉的记上，并落库
      unawaited(_flushAutosave());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('重新打标失败，标签已标记为待重打，可稍后重试'),
        backgroundColor: AppColors.red,
      ));
    } finally {
      if (mounted) setState(() => _retaggingCount = 0);
    }
  }

  /// 每次改动都自动落库：只要不按 ⌘Z，下次进来就是上次的状态。
  ///
  /// 因此没有「保存草稿」也没有「确认切分」——那两个动作存在的前提是
  /// 「有未保存状态」，而现在没有。
  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(
        const Duration(milliseconds: 800), () => unawaited(_flushAutosave()));
  }

  Future<void> _flushAutosave() async {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    final editor = _editor;
    if (editor == null || !_isEditable) return;
    final units = editor.units;
    if (_savedUnits != null &&
        const ListEquality<SemanticUnit>().equals(_savedUnits!, units)) {
      return;
    }
    try {
      await _tasks!.saveSegmentationDraft(_task, units);
      _task = _task.copyWith(units: units);
      _savedUnits = units;
    } catch (e) {
      // 存不上必须让用户知道，否则他以为改动已经留住了
      AppLog.warn('自动保存失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showSaveFailure('自动保存');
    }
  }

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
    final sourcePath = widget.task.sourcePath;
    // 空白任务没有原片，也就没有原片缩略图这一条轨
    if (videoInfo == null || sourcePath == null) return;
    try {
      final resolved = await _resolveMedia();
      final media = await resolved.builder.build(
        videoPath: sourcePath,
        taskId: widget.task.id,
        durationMs: videoInfo.duration.inMilliseconds,
        workDir: resolved.workDir,
      );
      if (!mounted) return;
      setState(() => _media = media);
    } catch (e) {
      AppLog.warn('时间线媒体加载失败（taskId=${widget.task.id}）：$e');
      if (!mounted) return;
      setState(() => _mediaFailed = true);
    }
  }

  /// 进入矩阵导出。
  ///
  /// 这里曾经是「确认切分，进入替换选材」——切分和选材已经合并在本工作台里
  /// 交替进行，那道闸门连同它的落库副作用一并删掉了（改动现在随手就存）。
  Future<void> _openExport() async {
    final editor = _editor;
    if (editor == null) return;
    // 成片放到「影片」目录下按任务分文件夹：跟原片、跟缓存都分开，
    // 用户拿完就走，不必在应用数据目录里翻
    final home = Platform.environment['HOME'] ?? '.';
    final outputDir = Directory(p.join(home, 'Movies', 'ishkafel',
        _safeName('${_task.name}_${_task.id}')));
    await showExportDialog(
      context,
      taskId: _task.id,
      taskName: _task.name,
      sourcePath: _task.sourcePath,
      units: editor.units,
      replacements: _replacements ?? const [],
      bgm: _task.bgm,
      voiceAudio: _voiceAudio,
      // 导出前要核对「选了音色的单元是不是都生成了配音」——少了会静默出原声
      voices: _task.voices,
      vocalsPath: _task.vocalsPath,
      // 上次导到哪儿就默认还导到哪儿——同一个项目往往一直往同一个位置出片
      outputDir: _task.exports.isEmpty
          ? outputDir
          : Directory(_task.exports.last.outputDir),
      onExported: _recordExport,
      exports: _task.exports,
      // 整体替换的成片时长跟候选走——不给这个，确认页会按原片长度报，
      // 和底部摘要写的成片时长对不上
      materialDurations: {
        for (final m in _task.pickedMaterials)
          if (m.durationMs != null) m.id: m.durationMs!,
      },
    );
  }

  /// 把这一次导出记进项目。
  ///
  /// 项目没有终态（原片放在那儿，明天换一批素材还能再导），有始有终的是每
  /// 一次导出——「哪天、导了几条、成了几条、在哪个目录」。
  Future<void> _recordExport(ExportRecord record) async {
    try {
      await _tasks!.addExportRecord(_task, record);
      if (mounted) {
        setState(() =>
            _task = _task.copyWith(exports: [..._task.exports, record]));
      }
    } catch (e) {
      // 记不上不该影响已经导好的片子，但要留痕
      AppLog.warn('导出记录落库失败（taskId=${widget.task.id}）：$e');
    }
  }

  /// 任务名会进文件路径，斜杠与冒号在 macOS 上都是雷
  static String _safeName(String name) =>
      name.replaceAll(RegExp(r'[/:\\]'), '_');

  /// 保存类操作失败的统一用户提示：说清做什么失败了与可能的原因，
  /// 不把原始异常文本摊给用户（详情已进日志）。
  void _showSaveFailure(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$what保存失败，请检查磁盘空间后重试'),
        backgroundColor: AppColors.red,
      ),
    );
  }

  /// 返回。改动是随手落库的，没有「未保存」这回事，因此不再拦截——
  /// 只把还在防抖窗口里的那次改动补写掉，否则改完立刻返回会丢。
  Future<void> _handleBackRequest() async {
    await _flushAutosave();
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  /// 把「哪些单元/镜头挑过替换素材」推给编辑器——挑过的就钉死切分。
  ///
  /// 为什么必须钉：替换方案按下标记。切一刀、并一次，下标全变，原本钉在
  /// S6 上的素材就跑到别的镜头上去了；改边界则会让已经按旧时长变速好的
  /// 切片全部作废，而用户毫不知情。见 [EditLocks]
  void _syncEditLocks() =>
      _editor?.locks = EditLocks.of(_replacements ?? const []);

  /// 右栏改了替换方案：立刻落库，并让底部栏的组合数与 tab 角标跟着更新
  Future<void> _onReplacementsChanged(List<UnitReplacement> next) async {
    if (!_isEditable) return;
    setState(() => _replacements = next);
    _syncEditLocks();
    _pinMaterials();
    try {
      await _tasks!.savePickingPlan(_task, next);
      _task = _task.copyWith(replacements: next);
    } catch (e) {
      AppLog.warn('替换方案落库失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showSaveFailure('替换方案');
    }
  }

  /// 右栏落地了新的已选素材：跟着存盘。存失败不打断选材——盘上少一条记录
  /// 只影响「下次进来还看不看得见」，不影响这次的方案
  Future<void> _onPickedMaterialsChanged(List<PickedMaterial> next) async {
    if (!_isEditable) return;
    if (const DeepCollectionEquality().equals(_task.pickedMaterials, next)) {
      return;
    }
    try {
      await _tasks!.savePickedMaterials(_task, next);
      _task = _task.copyWith(pickedMaterials: next);
    } catch (e) {
      AppLog.warn('已选素材落库失败（taskId=${widget.task.id}）：$e');
    }
  }

  /// 已选素材本体的本地固定。全应用共用一份缓存目录（和导出读的是同一个），
  /// 但固定集合是按任务来的——所以每个工作台各持一个实例
  PickedMediaCache? _mediaCache;

  /// 配乐同理：选中就下到本地，别人在素材库那边删了也不影响这条任务。
  /// 此前配乐是「用到才下」，从选完到导出中间同样有被删的窗口
  PickedMediaCache? _bgmMediaCache;

  /// 下载动作来自 [materialFetcherProvider]（和导出读同一个缓存目录）；
  /// 没接（测试环境）就不固定
  PickedMediaCache? _buildMediaCache() {
    final fetch = ref.read(materialFetcherProvider);
    final dataDir = ref.read(dataDirProvider);
    if (fetch == null || dataDir == null) return null;
    // 下完顺手转成预览代理——预览链路上每一段都是同一个规格，播放器在接缝处
    // 才不必重建解码器（见 [ProxySpec]）。**导出不走这里**，它读的是
    // material_cache 里的原始下载
    return PickedMediaCache(
      fetch: (id) async => _proxyBuilder(dataDir)
          .build(path: await fetch(id), frameRate: _frameRateArg),
      cacheDir: Directory(p.join(dataDir.path, 'material_cache')),
    );
  }

  /// 预览代理的生成器。原片与候选素材共用一条路、共用一份缓存目录：
  /// 同一个内容指纹只转一次
  ProxyBuilder _proxyBuilder(Directory dataDir) => ProxyBuilder(
        cache: RenderedCache(
          dir: Directory(p.join(dataDir.path, 'preview_proxy')),
          run: const ResolvingProcessRunner().call,
        ),
        run: const ResolvingProcessRunner().call,
      );

  /// 代理跟着原片的帧率走——帧率一变，时间线上每一帧的位置都要重算，
  /// 而本产品所有切分边界都是按帧对齐的
  String get _frameRateArg =>
      frameRateArg(widget.task.videoInfo?.fps ?? 30);

  /// 原片的预览代理。转好之后重推轨道换上去；转不动就一直播原片
  Future<void> _buildSourceProxy() async {
    final dataDir = ref.read(dataDirProvider);
    final tracks = _tracks;
    final sourcePath = widget.task.sourcePath;
    // 空白任务没有原片，也就没有原片代理要转
    if (dataDir == null || tracks == null || sourcePath == null) return;
    final path = await _proxyBuilder(dataDir)
        .build(path: sourcePath, frameRate: _frameRateArg);
    if (!mounted || path == sourcePath) return;
    tracks.proxyPath = path;
    _syncPreviewAudio();
  }



  /// 配乐的固定。曲子按 id 从当前方案里找——方案里存的就是完整的
  /// [BgmMaterial]，不必再去库里查一次
  PickedMediaCache? _buildBgmMediaCache() {
    final fetch = ref.read(bgmFetcherProvider);
    final dataDir = ref.read(dataDirProvider);
    if (fetch == null || dataDir == null) return null;
    return PickedMediaCache(
      extension: 'mp3',
      fetch: (id) {
        final material = _task.bgm.materialById(id);
        if (material == null) {
          throw StateError('这首配乐已经不在方案里了');
        }
        return fetch(material);
      },
      cacheDir: Directory(p.join(dataDir.path, 'bgm_cache')),
    );
  }

  /// 把方案里用到的配乐固定住。选完、改完、刚进工作台都要调一次
  void _pinBgm() {
    _bgmMediaCache?.pinAll({for (final m in _task.bgm.materials) m.id});
  }

  /// 把方案里用到的替换素材固定住——**打开工作台就做，不等用户点开选材面板**。
  ///
  /// 此前这一步只在「替换素材」那个 tab 里做。于是打开一条早就选好素材的任务、
  /// 直接按播放，素材从没被固定过，预览读的是 material_cache 里**没有代理化**
  /// 的原始下载：规格和别的段落对不上，接缝处照旧要重建解码器。配乐那边早就是
  /// 进工作台就固定的，素材没有理由两样。
  void _pinMaterials() {
    final cache = _mediaCache;
    final replacements = _replacements;
    if (cache == null || replacements == null) return;
    cache.pinAll({
      for (final r in replacements) ...[
        ...r.wholeCandidateIds,
        for (final ids in r.shotCandidateIds.values) ...ids,
      ],
    });
  }

  /// 首帧图落在任务数据目录下。没有数据目录（测试环境）就不落地——
  /// 托盘照样能画，只是重开就没了
  PickedMaterialStore? get _defaultPickedStore {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return null;
    return PickedMaterialStore(
      dir: Directory(p.join(dataDir.path, 'picked_thumbs', widget.task.id)),
      fetch: httpBytes,
    );
  }


  /// 素材/配乐的落地状态变了就重画底部栏——导出按钮的可用性挂在它上面
  void _onMediaCacheChanged() {
    if (mounted) setState(() {});
    unawaited(_backfillDurations());
    // 素材刚落地/刚规格化完，轨道要换上真正该播的那一份。少了这一句，
    // 预览会一直播启动那一刻的约定路径——也就是**没规格化过的原始下载**，
    // 于是替换点照旧要重建解码器，规格化等于白做
    _syncPreviewAudio();
  }

  /// 补齐已选素材的时长。
  ///
  /// 勾选那一刻规格可能还在探测中，落地记录里就存了个空——而整体替换要靠它
  /// 算「这一段在成片里有多长」。缺了的话会按原坑位长度铺，EDL 里写的
  /// length 比候选本身还长，播到候选结尾那一段就没东西了（真机上就这么错的）。
  ///
  /// 素材本来就固定在本地，ffprobe 一次几十毫秒，补完写回任务，之后不再探。
  Future<void> _backfillDurations() async {
    final cache = _mediaCache;
    if (cache == null || _backfillingDurations) return;
    final missing = [
      for (final m in _task.pickedMaterials)
        if (m.durationMs == null && cache.localPathOf(m.id) != null) m,
    ];
    if (missing.isEmpty) return;

    _backfillingDurations = true;
    try {
      final probe = FfprobeService(run: const ResolvingProcessRunner().call);
      final updated = <int, int>{};
      for (final m in missing) {
        try {
          final ms = (await probe.probe(cache.localPathOf(m.id)!))
              .duration
              .inMilliseconds;
          if (ms > 0) updated[m.id] = ms;
        } catch (e) {
          // 探不出来就先空着，下次进来再试；不要用 0 顶——那会把后面所有
          // 段落挤成一团
          AppLog.warn('补取已选素材 ${m.id} 的时长失败：$e');
        }
      }
      if (updated.isEmpty || !mounted) return;
      await _onPickedMaterialsChanged([
        for (final m in _task.pickedMaterials)
          updated.containsKey(m.id)
              ? PickedMaterial(
                  id: m.id,
                  name: m.name,
                  voiceover: m.voiceover,
                  sceneDescription: m.sceneDescription,
                  thumbPath: m.thumbPath,
                  durationMs: updated[m.id],
                )
              : m,
      ]);
      _syncPreviewAudio();
    } finally {
      _backfillingDurations = false;
    }
  }

  bool _backfillingDurations = false;

  ReplacementPlan get _plan => ReplacementPlan(_replacements ?? const []);

  String _summaryText(SegmentationEditorController editor) =>
      workbenchSummaryText(
        units: editor.units,
        durationMs: editor.durationMs,
        dirty: editor.dirty,
        hasTagGroups: widget.task.unitTagGroup != null ||
            widget.task.shotTagGroup != null,
        composedMs: _tracks?.plan.totalMs,
        blankFill: _task.isBlank
            ? BlankUnitOps.filledStat(editor.units,
                durationOf: _pickedDurationOf)
            : null,
      );

  /// 这个分子挑中的素材有多长；null 表示还没挑。空白任务的时长统计靠它
  int? _pickedDurationOf(int unitIndex) {
    final replacements = _replacements ?? const [];
    if (unitIndex >= replacements.length) return null;
    final replacement = replacements[unitIndex];
    if (replacement.mode != ReplacementMode.whole) return null;
    final id = replacement.wholePreviewId ??
        (replacement.wholeCandidateIds.isEmpty
            ? null
            : replacement.wholeCandidateIds.first);
    if (id == null) return null;
    for (final material in _task.pickedMaterials) {
      if (material.id == id) return material.durationMs;
    }
    return null;
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
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        // 已经 pop 了也要把防抖窗口里的改动补写掉
        unawaited(_flushAutosave());
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: WorkbenchTopBar(
          task: _task,
          onBack: _handleBackRequest,
          onEditTagGroups: _isEditable ? _editTagGroups : null,
        ),
        body: Column(
          children: [
            if (_playbackDegraded) const PlaybackDegradedBanner(),
            if (_retaggingCount > 0) RetaggingBanner(unitCount: _retaggingCount),
            // 多轨播放不需要「正在合成」——只有变速切片和取不到的配乐
            // 才有话要说
            if (_tracks?.notice case final notice?)
              PreviewAudioBanner(
                text: notice,
                building: (_tracks?.speedFitter?.pending ?? 0) > 0,
                onRetry: _retryPreviewAudio,
              ),
            if (missingVocalsNotice(_task.bgm, _task.voices, _task.vocalsPath,
                    isBlank: _task.isBlank)
                case final notice?)
              PreviewAudioBanner(text: notice, building: false),
            if (_voiceProgress case final p?)
              VoiceGeneratingBanner(done: p.$1, total: p.$2),
            // 被别人占着时整页只读。只禁不说的话，用户只会以为软件坏了
            if (_lock case final lock?)
              TaskLockBanner(holder: lock.holder, onTakeover: _takeoverLock),
            Expanded(
              child: WorkbenchBody(
                // 整体替换后这一段在成片里多长——时间线上标出来
                composedDurations: _composedDurations,
                onBgmResize: _isEditable ? _resizeBgm : null,
                onBgmDelete: _isEditable ? _deleteBgm : null,
                editor: editor,
                // 分子手动加只发生在空白任务上。翻新任务的分子是分析切出来的，
                // 给它一个「添加」按钮只会让人误以为能凭空插一段
                onAddUnit: _task.isBlank && _isEditable && _lock == null
                    ? _addBlankUnit
                    : null,
                unitTagEditor: _task.isBlank ? _blankTagEditor : null,
                onDeleteUnit: _task.isBlank && _isEditable && _lock == null
                    ? _deleteBlankUnit
                    : null,
                playback: playback,
                videoWidget: _videoWidget,
                media: _media,
                mediaStatus: _mediaStatus,
                playhead: _playhead,
                readOnly: !_isEditable || _lock != null,
                clock: widget.clock,
                voices: _task.voices,
                replacements: _replacements ?? const [],
                onChangeVoice: _isEditable ? _changeVoice : null,
                previewVoice: (i) =>
                    _voiceAudio.containsKey(i) ? () => _previewVoice(i) : null,
                candidateBadge: candidateBadgeText(_replacements ?? const []),
                bgm: _task.bgm,
                onBgmRangeSelected: _isEditable ? _pickBgmForRange : null,
                onBgmSegmentTap: _isEditable ? _editBgmSegment : null,
                candidatePanel: CandidateTab(
                  editor: editor,
                  shotTagGroups: _task.shotTagGroups,
                  unitTagGroups: _task.unitTagGroups,
                  initialReplacements: _replacements,
                  onReplacementsChanged: _onReplacementsChanged,
                  readOnly: !_isEditable || _lock != null,
                  project: _task.project,
                  pickedMaterials: _task.pickedMaterials,
                  onPickedMaterialsChanged: _onPickedMaterialsChanged,
                  pickedStore: widget.pickedStore ?? _defaultPickedStore,
                  mediaCache: _mediaCache,
                  contentService: widget.contentService,
                  candidateProbe: widget.candidateProbe,
                  tagService: widget.tagService,
                ),
              ),
            ),
          ],
        ),
        // 摘要含单元数/镜头数/dirty 标记，只随编辑器变化重建，不随播放位置重建
        bottomNavigationBar: AnimatedBuilder(
          animation: editor,
          builder: (context, _) {
            // 画面素材与配乐用同一把闸：任何一样没落到本地都不给导出
            var pending = 0;
            var failed = 0;
            for (final cache in [_mediaCache, _bgmMediaCache]) {
              if (cache == null) continue;
              for (final id in cache.notReady) {
                pending++;
                if (cache.statusOf(id) == PickedMediaStatus.failed) failed++;
              }
            }
            final blocked = exportBlockedReason(_plan,
                pendingMedia: pending, failedMedia: failed);
            return WorkbenchBottomBar(
              summaryText: _summaryText(editor),
              voiceCount: _task.voices.assignedUnits.length,
              onGenerateVoices:
                  _isEditable && _voiceProgress == null ? _generateVoices : null,
              combinationText: _plan.isEmpty ? null : combinationSummaryText(_plan),
              blockedReason: blocked,
              onExport: blocked == null ? _openExport : null,
            );
          },
        ),
      ),
    );
  }
}
