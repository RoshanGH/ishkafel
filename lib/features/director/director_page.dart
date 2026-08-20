import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/audio_preview.dart';
import '../../core/audio/tts_client.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/script_transcriber.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_repository.dart';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/rendered_cache.dart';
import '../../core/playback/media_kit_follower.dart';
import '../../core/playback/media_kit_playback.dart';
import '../../core/playback/multitrack_playback.dart';
import '../../core/playback/playback_controller.dart';
import '../../core/playback/track_plan.dart';
import '../../core/script/script_export.dart';
import '../../core/script/script_track_plan.dart';
import '../../core/script/shot_allocation.dart';
import '../../core/script/speed_clip_renderer.dart';
import '../picking/picked_media_cache.dart';
import '../picking/picking_providers.dart';
import '../settings/settings_providers.dart';
import '../tasks/new_task_wizard/wizard_providers.dart';
import '../tasks/task_list_controller.dart';
import '../workbench/bgm_picker_sheet.dart';
import 'director_providers.dart';
import 'find_shots_sheet.dart';
import 'line_board.dart';
import 'script_panel.dart';
import 'start_guide.dart';
import 'subtitle_style_sheet.dart';
import 'voice_select_dialog.dart';

/// 编导台——「脚本成片」的工作页（对仗审片台）。
///
/// 三栏：左 = 脚本（唯一的真相 + 总览导航）；中 = 预览（成片的影子）；
/// 右 = 当前行的工作台（聚焦深工）。见 docs/2026-08-19 设计稿。
class DirectorPage extends ConsumerStatefulWidget {
  final RenewTask task;

  /// 预览播放后端。缺省三轨真实播放器（画面主时钟 + 配音跟随）；
  /// 测试注入假实现或 null 工厂，不碰 libmpv
  final PlaybackController? Function()? playbackFactory;

  const DirectorPage({super.key, required this.task, this.playbackFactory});

  @override
  ConsumerState<DirectorPage> createState() => _DirectorPageState();
}

/// 「从视频提取脚本」此刻的状态：没在跑 / 跑到哪一步 / 挂在哪
sealed class _ExtractState {
  const _ExtractState();
}

class _ExtractRunning extends _ExtractState {
  final ScriptTranscribeStage stage;
  const _ExtractRunning(this.stage);
}

class _ExtractFailed extends _ExtractState {
  final String message;
  const _ExtractFailed(this.message);
}

class _DirectorPageState extends ConsumerState<DirectorPage> {
  late RenewTask _task = widget.task;
  late ScriptDoc _doc = widget.task.script ?? ScriptDoc.empty();
  int _selected = 0;

  /// 刚插入的行：让它的输入框自动聚焦（回车后手不离键盘）
  String? _autofocusLineId;

  Timer? _autosave;
  bool _saving = false;
  TaskLockFile? _lock;
  Timer? _lockHeartbeat;
  String? _blockedBy;

  _ExtractState? _extract;

  /// 用户在空脚本上点了「直接开始写」：起步引导让位给预览
  bool _guideDismissed = false;

  /// 正在生成配音的行 id（生成是异步的，期间行可能被移动，下标不可靠）
  final Set<String> _generatingLineIds = {};

  /// 正在试听配音的行 id；试听播放器整页共用一个
  String? _playingLineId;
  final AudioPreview _voicePreview = AudioPreview();

  /// initState 里取好：dispose 阶段还要落一次盘，那时不能再碰 ref
  late final TaskRepository _repo;

  /// 展开详情的镜头：(行下标, 镜头下标)。展开发生在块内，一次一个
  (int, int)? _expandedShot;

  /// 参考段缩略图：行 id → 本地 jpg（抽一帧缓存一帧）
  final Map<String, String> _refThumbs = {};
  final Set<String> _refThumbsRendering = {};

  /// 右板滚动控制（左栏点行 → 滚到对应块）
  final ScrollController _boardScroll = ScrollController();

  /// 素材固定：挑中的镜头视频下到本地（与工作台/导出同一份缓存目录）。
  /// 下载器未接（测试环境/凭据不全）时为 null，卡片不显示下载状态
  PickedMediaCache? _mediaCache;

  // ---- 整片预览 ----

  PlaybackController? _playback;
  Widget? _videoWidget;
  ScriptPlanResult _planResult =
      const ScriptPlanResult(plan: TrackPlan.empty, skippedLines: {});
  final ValueNotifier<int> _positionMs = ValueNotifier(0);
  bool _previewPlaying = false;
  StreamSubscription<int>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _previewRebuild;

  /// 变速切片：渲染好的路径按指纹存着；正在渲的记 key 防重复
  SpeedClipRenderer? _clipRenderer;
  final Map<String, String> _speedClips = {};
  final Set<String> _renderingClips = {};

  /// 配乐固定：选中即下到本地（与工作台同一份 bgm_cache）
  PickedMediaCache? _bgmCache;

  /// 批量自动打标进度（提取脚本后跑）：(已完成, 总数)；null = 没在跑
  (int, int)? _batchTagging;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(taskRepositoryProvider);
    _acquireLock();
    _mediaCache = _buildMediaCache();
    _mediaCache?.addListener(_onMediaCache);
    _bgmCache = _buildBgmCache();
    _bgmCache?.addListener(_onMediaCache);
    _pinBgm();
    _pinAllShots();
    _setupPreview();
  }

  PickedMediaCache? _buildBgmCache() {
    final fetch = ref.read(bgmFetcherProvider);
    final dataDir = ref.read(dataDirProvider);
    if (fetch == null || dataDir == null) return null;
    return PickedMediaCache(
      extension: 'mp3',
      fetch: (id) {
        final material = _doc.bgm;
        if (material == null || material.id != id) {
          throw StateError('这首配乐已经不在方案里了');
        }
        return fetch(material);
      },
      cacheDir: Directory(p.join(dataDir.path, 'bgm_cache')),
    );
  }

  void _pinBgm() {
    final material = _doc.bgm;
    if (material != null) _bgmCache?.pinAll({material.id});
  }

  // ---- 配乐 / 字幕 ----

  Future<void> _pickBgm() async {
    final total = _planResult.plan.totalMs;
    final choice = await showBgmPicker(
      context,
      rangeMs: total > 0 ? total : 15000,
      rangeLabel: '整条片子',
      canClear: _doc.bgm != null,
      projectIds: [if (_task.project != null) _task.project!.id],
      initialVolume: _doc.bgmVolume,
      initialMaterials: [if (_doc.bgm != null) _doc.bgm!],
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case BgmPicked(:final materials, :final previewIndex, :final volume):
        final material =
            materials.isEmpty ? null : materials[previewIndex.clamp(0, materials.length - 1)];
        _mutate((d) => d.withBgm(material, volume: volume));
        _pinBgm();
      case BgmVolumeChanged(:final volume):
        _mutate((d) => d.withBgm(_doc.bgm, volume: volume));
      case BgmCleared():
        _mutate((d) => d.withBgm(null));
    }
  }

  Future<void> _editSubtitleStyle() async {
    final style =
        await showSubtitleStyleSheet(context, initial: _doc.subtitle);
    if (style == null) return;
    _mutate((d) => d.withSubtitle(style));
  }

  void _setupPreview() {
    final playback = widget.playbackFactory != null
        ? widget.playbackFactory!()
        : MultitrackPlayback(
            video: MediaKitPlaybackController(),
            voice: MediaKitFollower(),
            bgm: MediaKitFollower(loop: true),
          );
    if (playback == null) return;
    _playback = playback;
    _videoWidget = switch (playback) {
      MultitrackPlayback() => playback.buildVideoWidget(),
      MediaKitPlaybackController() => playback.buildVideoWidget(),
      _ => null,
    };
    _positionSub = playback.positionMsStream.listen((ms) {
      if (mounted) _positionMs.value = ms;
    });
    _playingSub = playback.playingStream.listen((playing) {
      if (mounted && _previewPlaying != playing) {
        setState(() => _previewPlaying = playing);
      }
    });
    final dataDir = ref.read(dataDirProvider);
    if (dataDir != null) {
      _clipRenderer = SpeedClipRenderer(
        cache: RenderedCache(
          dir: Directory(
              p.join(dataDir.path, 'speed_fit_script', _task.id)),
          run: const ResolvingProcessRunner().call,
        ),
      );
    }
    _schedulePreviewRebuild();
  }

  /// 内容一变就排一次轨道重建（600ms 防抖）。画面轨没变时
  /// MultitrackPlayback 自己会挡住重复 open，不闪黑
  void _schedulePreviewRebuild() {
    if (_playback == null) return;
    _previewRebuild?.cancel();
    _previewRebuild =
        Timer(const Duration(milliseconds: 600), _rebuildPreview);
  }

  String _clipKey(LineShot s) =>
      '${s.materialId}|${s.trimStartMs}|${s.allocMs}|${s.speed}';

  Future<void> _rebuildPreview() async {
    final playback = _playback;
    if (playback == null || !mounted) return;
    // 变速镜头先渲对齐切片（按内容指纹缓存，改了才重渲）
    for (final line in _doc.lines) {
      for (final shot in line.shots) {
        if (shot.speed == 1.0 || shot.allocMs == null) continue;
        final key = _clipKey(shot);
        if (_speedClips.containsKey(key) ||
            _renderingClips.contains(key) ||
            _clipRenderer == null) {
          continue;
        }
        final src =
            shot.localSource ?? _mediaCache?.localPathOf(shot.materialId);
        if (src == null) continue;
        _renderingClips.add(key);
        unawaited(_clipRenderer!
            .render(
          materialId: shot.materialId,
          sourcePath: src,
          trimStartMs: shot.trimStartMs,
          allocMs: shot.allocMs!,
          speed: shot.speed,
        )
            .then((path) {
          _speedClips[key] = path;
          if (mounted) _schedulePreviewRebuild();
        }).catchError((Object e) {
          AppLog.warn('变速切片渲染失败（素材 ${shot.materialId}）：$e');
        }).whenComplete(() => _renderingClips.remove(key)));
      }
    }
    final result = buildScriptTrackPlan(_doc, sourceOf: (shot) {
      if (shot.speed != 1.0) {
        final clip = _speedClips[_clipKey(shot)];
        return clip == null ? null : ShotSource(clip);
      }
      final local = shot.localSource ?? _mediaCache?.localPathOf(shot.materialId);
      return local == null
          ? null
          : ShotSource(local, inMs: shot.trimStartMs);
    }, bgmPath: _doc.bgm == null ? null : _bgmCache?.localPathOf(_doc.bgm!.id));
    if (!mounted) return;
    setState(() => _planResult = result);
    if (playback is MultitrackPlayback) {
      await playback.setPlan(result.plan);
    }
  }

  Future<void> _togglePreviewPlay() async {
    final playback = _playback;
    if (playback == null) return;
    if (_previewPlaying) {
      await playback.pause();
    } else {
      await playback.play();
    }
  }

  // ---- 导出 ----

  bool _exporting = false;
  final ValueNotifier<ScriptExportProgress?> _exportProgress =
      ValueNotifier(null);

  Future<void> _exportScript() async {
    final cache = _mediaCache;
    final dataDir = ref.read(dataDirProvider);
    if (cache == null || dataDir == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('当前环境没有素材下载器，无法导出。')));
      return;
    }
    _flushNow();
    setState(() => _exporting = true);
    _exportProgress.value = const ScriptExportProgress('准备中', 0);
    // 模态进度：导出中不许再改内容，改了也不会进这一版成片
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportProgressDialog(progress: _exportProgress),
    ));
    final runner = ScriptExportRunner(
      workDir: Directory(p.join(dataDir.path, 'script_export', _task.id)),
      localPathOf: cache.localPathOf,
      localSourceOk: (path) => File(path).existsSync(),
      run: const ResolvingProcessRunner().call,
    );
    final stamp = DateTime.now();
    final outDir = p.join(Platform.environment['HOME'] ?? '.', 'Desktop',
        'ishkafel-脚本成片');
    final name = '#${_task.seq ?? ''}_'
        '${stamp.month.toString().padLeft(2, '0')}'
        '${stamp.day.toString().padLeft(2, '0')}_'
        '${stamp.hour.toString().padLeft(2, '0')}'
        '${stamp.minute.toString().padLeft(2, '0')}.mp4';
    try {
      final out = await runner.export(
        doc: _doc,
        outPath: p.join(outDir, name),
        bgmPath:
            _doc.bgm == null ? null : _bgmCache?.localPathOf(_doc.bgm!.id),
        onProgress: (progress) => _exportProgress.value = progress,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('成片已导出：$out'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: '在访达中显示',
          onPressed: () => Process.run('open', ['-R', out]),
        ),
      ));
    } on ScriptExportException catch (e) {
      AppLog.warn('脚本导出被拦/失败：${e.message} ${e.cause ?? ''}');
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('没能导出'),
            content: Text(e.message),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('知道了')),
            ],
          ),
        );
      }
    } catch (e) {
      AppLog.warn('脚本导出失败：$e');
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('导出失败，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  PickedMediaCache? _buildMediaCache() {
    final fetch = ref.read(materialFetcherProvider);
    final dataDir = ref.read(dataDirProvider);
    if (fetch == null || dataDir == null) return null;
    return PickedMediaCache(
      fetch: fetch,
      cacheDir: Directory(p.join(dataDir.path, 'material_cache')),
    );
  }

  void _onMediaCache() {
    if (mounted) setState(() {});
  }

  /// 把全部行的全部镜头固定到本地——挑中即下载，检索结果随时会变，
  /// 凡是进入方案的都要钉死（最高准则）
  void _pinAllShots() {
    final cache = _mediaCache;
    if (cache == null) return;
    cache.pinAll({
      for (final line in _doc.lines)
        for (final shot in line.shots) shot.materialId,
    });
  }

  static String get _holder => '人（编导台）';

  /// 与工作台/审核页同一套会话级互斥：谁先进谁处理
  void _acquireLock() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final lock = TaskLockFile(dataDir: dataDir, taskId: _task.id);
    if (!lock.acquire(_holder)) {
      _blockedBy = lock.read()?.holder ?? '别人';
      return;
    }
    _lock = lock;
    // 心跳让锁活着：写脚本可能一坐半小时，超时失效等于没锁
    _lockHeartbeat = Timer.periodic(
        const Duration(seconds: 20), (_) => lock.heartbeat(_holder));
  }

  /// 抢锁是破坏性的（对方之后的保存会被拒绝），与审核页同一套确认规矩
  Future<void> _forceTakeover() async {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前环境没有数据目录，无法接管')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('强制接管这个任务？'),
        content: Text('「${_blockedBy ?? '对方'}」之后的保存会被拒绝，'
            '它未落盘的改动可能丢失。确定要接管吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('接管')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final lock = TaskLockFile(dataDir: dataDir, taskId: _task.id);
    lock.forceTakeover(_holder);
    setState(() => _blockedBy = null);
    _lock = lock;
    _lockHeartbeat = Timer.periodic(
        const Duration(seconds: 20), (_) => lock.heartbeat(_holder));
  }

  @override
  void dispose() {
    _autosave?.cancel();
    _flushNow();
    _lockHeartbeat?.cancel();
    _lock?.release(_holder);
    _mediaCache?.removeListener(_onMediaCache);
    _mediaCache?.dispose();
    _bgmCache?.removeListener(_onMediaCache);
    _bgmCache?.dispose();
    _previewRebuild?.cancel();
    unawaited(_positionSub?.cancel());
    unawaited(_playingSub?.cancel());
    _playback?.dispose();
    _positionMs.dispose();
    unawaited(_voicePreview.dispose());
    super.dispose();
  }

  // ---- 配音 ----

  /// 给某行挑音色。选完只是记下——生成才花钱
  Future<void> _pickVoice(int index) async {
    final line = _doc.lines[index];
    // 预填：本行已选的，其次全文档最近一次用过的（连着几行同一个声音是常态）
    final fallback = _doc.lines
        .lastWhere((l) => l.voiceId != null, orElse: () => line)
        .voiceId;
    final picked = await showVoiceSelectDialog(context,
        selected: line.voiceId ?? fallback);
    if (picked == null) return;
    _mutate((d) => d.setVoiceId(index, picked));
  }

  /// 显式生成配音：设计稿定死——改字只标黄，点这里才调 API
  Future<void> _generateVoice(int index) async {
    final factory = ref.read(lineVoiceFactoryProvider);
    if (factory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务（语音合成），无法生成配音。')));
      return;
    }
    var line = _doc.lines[index];
    if (line.voiceId == null) {
      // 还没选音色：先弹选择器，选完直接接着生成——别让用户点两遍
      await _pickVoice(index);
      line = _doc.lines[index];
      if (line.voiceId == null) return;
    }
    final lineId = line.id;
    final old = line.voiceover;
    setState(() => _generatingLineIds.add(lineId));
    try {
      final service = factory(_task);
      final vo = await service.generate(
        lineId: lineId,
        text: line.text,
        voiceId: line.voiceId!,
        speechRate: line.speechRate,
      );
      if (!mounted) return;
      _mutate((d) => d.setVoiceoverById(lineId, vo));
      // 配音时长是这一行时间轴的根：根变了，镜头的时长分配跟着重算
      final updated = _doc.lines.firstWhere((l) => l.id == lineId);
      if (updated.shots.isNotEmpty) {
        _mutate((d) => d.setShotsById(
            lineId, ShotAllocation.distribute(updated.shots, vo.durationMs)));
      }
      _flushNow();
      // 新的落稳了才删旧的——失败时旧配音还能听
      if (old != null) service.deleteStale(old);
    } on TtsException catch (e) {
      AppLog.warn('配音生成失败（line=$lineId）：${e.message}');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('配音生成失败：${e.message}')));
      }
    } catch (e) {
      AppLog.warn('配音生成失败（line=$lineId）：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('配音生成失败，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _generatingLineIds.remove(lineId));
    }
  }

  // ---- 找镜头 ----

  /// 打开找镜头面板；确认后整组落回行上（按行 id，面板期间行可能被移动）
  Future<void> _findShots(int index) async {
    final line = _doc.lines[index];
    // 防撞车：同任务其他行已用的素材要在面板里标出来
    final usedBy = <int, int>{};
    for (var i = 0; i < _doc.lines.length; i++) {
      for (final shot in _doc.lines[i].shots) {
        if (shot.localSource != null) continue; // 参考段不参与防撞车
        usedBy.putIfAbsent(shot.materialId, () => i);
      }
    }
    final picked = await showFindShotsSheet(
      context,
      services: ref.read(shotSearchServicesProvider),
      tagger: ref.read(lineTaggerProvider),
      task: _task,
      lineIndex: index,
      line: line,
      usedBy: usedBy,
    );
    if (picked == null) return;
    // 挑完就把时长按行的根均分好（默认全自动预填，人只做否决）；
    // 行还没有根（没配音/没填时长）就先不分，界面会说清下一步
    final root = ShotAllocation.rootMsOf(line.withShots(picked.shots));
    final shots = root == null
        ? picked.shots
        : ShotAllocation.distribute(picked.shots, root);
    _mutate((d) =>
        d.setShotsById(line.id, shots).setTagsById(line.id, picked.tags));
    _flushNow();
    _pinAllShots();
  }

  // ---- 时长分配 ----

  void _updateShots(int index, List<LineShot> shots) {
    final line = _doc.lines[index];
    _mutate((d) => d.setShotsById(line.id, shots));
  }

  void _distribute(int index) {
    final line = _doc.lines[index];
    final root = ShotAllocation.rootMsOf(line);
    if (root == null) return;
    _updateShots(index, ShotAllocation.distribute(line.shots, root));
  }

  void _resizeShot(int index, int j, int newAllocMs) {
    final line = _doc.lines[index];
    final next = ShotAllocation.resize(line.shots, j, newAllocMs);
    if (next == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('调不动了：相邻镜头已经到底线（每镜最少 0.5 秒）。')));
      return;
    }
    _updateShots(index, next);
  }

  void _trimShot(int index, int j, int trimStartMs) {
    final line = _doc.lines[index];
    final next = [...line.shots];
    next[j] = ShotAllocation.setTrimStart(next[j], trimStartMs);
    _updateShots(index, next);
  }

  void _speedShot(int index, int j, double speed) {
    final line = _doc.lines[index];
    final next = [...line.shots];
    next[j] = ShotAllocation.setSpeed(next[j], speed);
    _updateShots(index, next);
  }

  // ---- 参考段（这一句在参考片里的原始画面）----

  /// 这一行的参考视频路径：行级上传的优先，其次整片提取的来源
  String? _refVideoOf(ScriptLine line) =>
      line.reference?.videoPath ?? _doc.refVideoPath;

  /// 参考分镜缩略图：取该镜中点帧（两端常踩转场），按 (行,镜) 缓存
  void _ensureRefThumb(ScriptLine line, int segIndex) {
    final ref = line.reference;
    final video = _refVideoOf(line);
    final dataDir = this.ref.read(dataDirProvider);
    if (ref == null || video == null || dataDir == null) return;
    final segments = ref.segments;
    if (segIndex < 0 || segIndex >= segments.length) return;
    final key = '${line.id}_$segIndex';
    if (_refThumbs.containsKey(key) || _refThumbsRendering.contains(key)) {
      return;
    }
    final out = p.join(dataDir.path, 'script_refs', _task.id, '$key.jpg');
    if (File(out).existsSync()) {
      _refThumbs[key] = out;
      return;
    }
    _refThumbsRendering.add(key);
    final seg = segments[segIndex];
    unawaited(() async {
      try {
        await Directory(p.dirname(out)).create(recursive: true);
        final mid = (seg.$1 + seg.$2) / 2000;
        final r = await const ResolvingProcessRunner().call('ffmpeg', [
          '-y', '-v', 'error',
          '-ss', mid.toStringAsFixed(3),
          '-i', video,
          '-frames:v', '1',
          '-vf', 'scale=-2:240',
          out,
        ]);
        if (r.exitCode == 0 && mounted) {
          setState(() => _refThumbs[key] = out);
        }
      } catch (e) {
        AppLog.warn('参考缩略图抽帧失败（$key）：$e');
      } finally {
        _refThumbsRendering.remove(key);
      }
    }());
  }

  /// 播放参考分镜：小窗循环播该镜区间
  Future<void> _playReference(int index, int segIndex) async {
    final line = _doc.lines[index];
    final ref = line.reference;
    final video = _refVideoOf(line);
    if (ref == null || video == null) return;
    final segments = ref.segments;
    if (segIndex < 0 || segIndex >= segments.length) return;
    if (!File(video).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('参考视频已不在原位，放回后才能播放。')));
      return;
    }
    final seg = segments[segIndex];
    await showDialog<void>(
      context: context,
      builder: (_) => _RefClipDialog(
          videoPath: video, startMs: seg.$1, endMs: seg.$2),
    );
  }

  /// 参考分镜一键作镜头：原片本地文件直接当镜头用
  void _useReference(int index, int segIndex) {
    final line = _doc.lines[index];
    final ref = line.reference;
    final video = _refVideoOf(line);
    if (ref == null || video == null) return;
    final segments = ref.segments;
    if (segIndex < 0 || segIndex >= segments.length) return;
    final seg = segments[segIndex];
    if (line.shots
        .any((s) => s.localSource == video && s.trimStartMs == seg.$1)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这段参考画面已经在这一行的镜头里了。')));
      return;
    }
    final shot = LineShot(
      // 负数占位：本地源不参与下载与防撞车，行内按区间起点保证唯一
      materialId: -(seg.$1 + 1),
      name: '参考画面',
      sceneDescription: '参考片 ${(seg.$1 / 1000).toStringAsFixed(1)}s'
          '~${(seg.$2 / 1000).toStringAsFixed(1)}s',
      durationMs: seg.$2 - seg.$1,
      localSource: video,
      trimStartMs: seg.$1,
    );
    final next = [...line.shots, shot];
    final root = ShotAllocation.rootMsOf(line);
    _updateShots(
        index, root == null ? next : ShotAllocation.distribute(next, root));
    _flushNow();
  }

  /// 给某一行上传参考视频（手写的行也能对照参考配镜）。
  /// 整段视频作为该行的参考区间；时长用 ffprobe 实探，不猜
  Future<void> _uploadReference(int index) async {
    final line = _doc.lines[index];
    final path = await ref.read(videoFilePickerProvider)();
    if (path == null || !mounted) return;
    int durationMs;
    try {
      final r = await const ResolvingProcessRunner().call('ffprobe', [
        '-v', 'quiet', '-show_entries', 'format=duration', '-of', 'csv=p=0',
        path,
      ]);
      final seconds = double.tryParse('${r.stdout}'.trim());
      if (seconds == null || seconds <= 0) {
        throw StateError('时长读不出来');
      }
      durationMs = (seconds * 1000).round();
    } catch (e) {
      AppLog.warn('参考视频探测失败（$path）：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('读不出这条视频的时长，确认它是完整的视频文件。')));
      }
      return;
    }
    _mutate((d) => d.setReferenceById(
        line.id, LineRef(startMs: 0, endMs: durationMs, videoPath: path)));
    _flushNow();
  }

  Future<void> _togglePlayVoice(int index) async {
    final line = _doc.lines[index];
    final vo = line.voiceover;
    if (vo == null) return;
    if (_playingLineId == line.id) {
      setState(() => _playingLineId = null);
      await _voicePreview.stop();
      return;
    }
    setState(() => _playingLineId = line.id);
    await _voicePreview.play(vo.audioPath);
    // 简单起见按时长收尾：播完把按钮复位（期间切行/重播由上面的分支处理）
    Future.delayed(Duration(milliseconds: vo.durationMs + 200), () {
      if (mounted && _playingLineId == line.id) {
        setState(() => _playingLineId = null);
      }
    });
  }

  /// 改动随手落库（800ms 防抖）——写作软件没有「保存」这回事
  void _mutate(ScriptDoc Function(ScriptDoc) f) {
    setState(() {
      _doc = f(_doc);
      _saving = true;
    });
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 800), _flushNow);
    _schedulePreviewRebuild();
  }

  void _flushNow() {
    _autosave?.cancel();
    _task = _task.copyWith(script: _doc, updatedAt: DateTime.now());
    unawaited(_repo.save(_task).then((_) {
      if (mounted) setState(() => _saving = false);
    }).catchError((Object e) {
      AppLog.warn('脚本落库失败（taskId=${_task.id}）：$e');
    }));
  }

  bool get _scriptIsPristine =>
      _doc.lines.length == 1 && _doc.lines.single.text.trim().isEmpty;

  /// 「从视频提取脚本」全流程：选文件 → （非空时确认覆盖）→ 三步提取 →
  /// 覆盖填充。失败给原因和重试，不静默。
  Future<void> _extractFromVideo() async {
    final transcriber = ref.read(scriptTranscriberProvider);
    if (transcriber == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务（语音识别与语义分行），无法从视频提取脚本。')));
      return;
    }
    if (!_scriptIsPristine) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('用提取结果替换当前脚本？'),
          content: Text(
              '当前脚本已有 ${_doc.lines.length} 行，提取出的台词会整体替换它们，'
              '此操作无法撤销。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('替换')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!mounted) return;
    final path = await ref.read(videoFilePickerProvider)();
    if (path == null || !mounted) return;

    setState(() =>
        _extract = const _ExtractRunning(ScriptTranscribeStage.extractingAudio));
    try {
      final lines = await transcriber.extract(path, onStage: (stage) {
        if (mounted) setState(() => _extract = _ExtractRunning(stage));
      });
      if (!mounted) return;
      setState(() {
        // 来源视频跟文档走：行上的 reference 区间都指向它（参考视频列）
        _doc = ScriptDoc(lines,
            subtitle: _doc.subtitle,
            bgm: _doc.bgm,
            bgmVolume: _doc.bgmVolume,
            refVideoPath: path);
        _selected = 0;
        _extract = null;
        _guideDismissed = true;
      });
      _flushNow();
      unawaited(_offerBatchTagging());
    } on ScriptTranscribeException catch (e) {
      AppLog.warn('脚本提取失败（$path）：${e.cause ?? e.message}');
      if (mounted) setState(() => _extract = _ExtractFailed(e.message));
    } catch (e) {
      AppLog.warn('脚本提取失败（$path）：$e');
      if (mounted) {
        setState(() =>
            _extract = const _ExtractFailed('提取失败，请稍后重试。'));
      }
    }
  }

  /// 提取完成后追问：要不要给全部台词自动打标（复刻链路的「两层自动
  /// 打标」的行级版）。打标要花 AI 调用，必须显式确认，不许静默扣钱
  Future<void> _offerBatchTagging() async {
    final tagger = ref.read(lineTaggerProvider);
    if (tagger == null || _task.unitTagGroups.isEmpty || !mounted) return;
    final voiced = [
      for (final l in _doc.lines)
        if (l.type == ScriptLineType.voiced) l,
    ];
    if (voiced.isEmpty) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('顺手给台词打上标签？'),
        content: Text('共 ${voiced.length} 句。标签来自任务选定的标签组，'
            '找镜头时会自动按它检索（约 ${voiced.length} 次 AI 调用）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('先不用')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('打标')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _batchTagging = (0, voiced.length));
    var failed = 0;
    for (var i = 0; i < voiced.length; i++) {
      if (!mounted) return;
      try {
        final tags = await tagger.tag(
          text: voiced[i].text,
          groups: _task.unitTagGroups,
          constraint: _task.unitTagPrompt,
        );
        if (!mounted) return;
        if (tags.isNotEmpty) {
          _mutate((d) => d.setTagsById(voiced[i].id, tags));
        }
      } catch (e) {
        failed++;
        AppLog.warn('批量打标失败（第 ${i + 1} 句）：$e');
      }
      if (mounted) setState(() => _batchTagging = (i + 1, voiced.length));
    }
    if (!mounted) return;
    setState(() => _batchTagging = null);
    _flushNow();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(failed == 0
            ? '打标完成：${voiced.length} 句台词的标签已挂上'
            : '打标完成，但有 $failed 句失败（可在找镜头面板里单独重打）')));
  }

  @override
  Widget build(BuildContext context) {
    if (_blockedBy != null) return _blockedView();
    final extracting = _extract is _ExtractRunning;
    // 起步引导激活时右栏收敛：一边问「从哪里开始」、一边摆开行工作台，
    // 两套话语打架（真机截图核对时发现）
    final showGuide =
        _scriptIsPristine && !_guideDismissed && _extract == null;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(children: [
        _topBar(),
        const Divider(height: 1, thickness: 1, color: AppColors.border),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // 左：脚本——唯一的真相
            Container(
              width: 360,
              color: AppColors.surface,
              child: Column(children: [
                if (_extract != null) _extractBanner(),
                if (_batchTagging case (final done, final total))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
                    child: Row(children: [
                      const SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: AppColors.accentBlue)),
                      const SizedBox(width: AppSpacing.sm),
                      Text('正在给台词打标（$done/$total）',
                          style: const TextStyle(
                              fontSize: AppFontSize.caption,
                              color: AppColors.textSecondary)),
                    ]),
                  ),
                Expanded(
                  child: IgnorePointer(
                    ignoring: extracting,
                    child: ScriptPanel(
                      doc: _doc,
                      selected: _selected,
                      autofocusLineId: _autofocusLineId,
                      onSelect: (i) => setState(() {
                        _selected = i;
                        _expandedShot = null;
                      }),
                      onInsertAfter: (i) {
                        _mutate((d) => d.insertAfter(i));
                        setState(() {
                          _selected = i + 1;
                          _autofocusLineId = _doc.lines[i + 1].id;
                          _guideDismissed = true;
                        });
                      },
                      onRemove: (i) {
                        _mutate((d) => d.removeAt(i));
                        if (_selected >= _doc.lines.length) {
                          setState(
                              () => _selected = _doc.lines.length - 1);
                        }
                      },
                      onMove: (from, to) {
                        _mutate((d) => d.move(from, to));
                        setState(() => _selected = to);
                      },
                      onTextChanged: (i, text) =>
                          _mutate((d) => d.updateText(i, text)),
                    ),
                  ),
                ),
              ]),
            ),
            const VerticalDivider(
                width: 1, thickness: 1, color: AppColors.border),
            // 中：预览（定宽，播放器窄而居中）；空脚本时让位给起步引导
            if (showGuide)
              Expanded(child: _startGuide())
            else ...[
              SizedBox(width: 400, child: _previewStage()),
              const VerticalDivider(
                  width: 1, thickness: 1, color: AppColors.border),
              // 右：分镜编辑板——所有行的工作块从上到下铺开（行带式，
              // 见 2026-08-20 设计推演；检查器范式已废）
              Expanded(
                child: Container(
                  color: AppColors.surface,
                  child: LineBoard(
                    doc: _doc,
                    selected: _selected,
                    expandedShot: _expandedShot,
                    onExpandShot: (v) => setState(() => _expandedShot = v),
                    generatingLineIds: _generatingLineIds,
                    playingLineId: _playingLineId,
                    controller: _boardScroll,
                    handlers: LineBoardHandlers(
                      onFocusLine: _focusLine,
                      onFindShots: _findShots,
                      onRemoveShot: (index, j) {
                        final line = _doc.lines[index];
                        final next = [...line.shots]..removeAt(j);
                        // 删镜后剩下的按根重新均分——空出的时长不能凭空消失
                        final root = ShotAllocation.rootMsOf(line);
                        _mutate((d) => d.setShotsById(
                            line.id,
                            root == null || next.isEmpty
                                ? next
                                : ShotAllocation.distribute(next, root)));
                        setState(() => _expandedShot = null);
                      },
                      onResizeShot: _resizeShot,
                      onTrimShot: _trimShot,
                      onSpeedShot: _speedShot,
                      onDistribute: _distribute,
                      onManualMs: (index, ms) =>
                          _mutate((d) => d.setManualMs(index, ms)),
                      onPickVoice: _pickVoice,
                      onSpeechRate: (index, rate) =>
                          _mutate((d) => d.setSpeechRate(index, rate)),
                      onGenerateVoice: _generateVoice,
                      onTogglePlayVoice: _togglePlayVoice,
                      onPlayReference: _playReference,
                      onUseReference: _useReference,
                      onUploadReference: _uploadReference,
                      shotStatus: (id) => _mediaCache?.statusOf(id),
                      onRetryDownload: (id) => _mediaCache?.retry(id),
                      refThumbOf: (line, segIndex) {
                        _ensureRefThumb(line, segIndex);
                        return _refThumbs['${line.id}_$segIndex'];
                      },
                    ),
                  ),
                ),
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  /// 点块 = 「你正看着这一行」：左栏行选中 + 预览跳播到该行起点
  void _focusLine(int index) {
    setState(() {
      _selected = index;
      _expandedShot = null;
    });
    final start = _planResult.lineStarts[index];
    if (start != null) {
      unawaited(_playback?.seekMs(start));
    }
  }

  /// 顶栏：返回 + 身份（#编号 · 名字 · 模块徽标）+ 保存状态。
  /// 自动保存要**说出来**——用户不问「存了没」是因为界面一直在回答
  Widget _topBar() => Container(
        height: 48,
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Row(children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_ios_new,
                size: 15, color: AppColors.textSecondary),
            tooltip: '返回任务列表',
          ),
          const SizedBox(width: AppSpacing.xs),
          if (_task.seq != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text('#${_task.seq}',
                  style: const TextStyle(
                      fontSize: AppFontSize.emphasis,
                      color: AppColors.textTertiary,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
          Flexible(
            child: Text(_task.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: AppFontSize.emphasis,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ),
          const SizedBox(width: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.accentBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text('编导台',
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accentBlueLight)),
          ),
          const Spacer(),
          Text(_saving ? '保存中…' : '更改已自动保存',
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textTertiary)),
          const SizedBox(width: AppSpacing.sm),
          IconButton(
            key: const ValueKey('director-bgm'),
            visualDensity: VisualDensity.compact,
            onPressed: _pickBgm,
            iconSize: 16,
            icon: Icon(Icons.music_note_outlined,
                color: _doc.bgm != null
                    ? AppColors.accentBlueLight
                    : AppColors.textSecondary),
            tooltip: _doc.bgm == null ? '配乐' : '配乐：${_doc.bgm!.name}',
          ),
          IconButton(
            key: const ValueKey('director-subtitle'),
            visualDensity: VisualDensity.compact,
            onPressed: _editSubtitleStyle,
            iconSize: 16,
            icon: const Icon(Icons.subtitles_outlined,
                color: AppColors.textSecondary),
            tooltip: '字幕样式',
          ),
          const SizedBox(width: AppSpacing.xs),
          _extractButton(),
          const SizedBox(width: AppSpacing.sm),
          FilledButton.icon(
            key: const ValueKey('director-export'),
            onPressed: _exporting ? null : _exportScript,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accentBlue,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: 6),
              textStyle: const TextStyle(
                  fontSize: AppFontSize.body, fontWeight: FontWeight.w600),
            ),
            icon: const Icon(Icons.ios_share, size: 14),
            label: Text(_exporting ? '导出中…' : '导出成片'),
          ),
          const SizedBox(width: AppSpacing.xs),
        ]),
      );

  Widget _extractButton() {
    final available = ref.watch(scriptTranscriberProvider) != null;
    final running = _extract is _ExtractRunning;
    final button = OutlinedButton.icon(
      key: const ValueKey('director-extract-script'),
      onPressed: available && !running ? _extractFromVideo : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.border),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: 6),
        textStyle: const TextStyle(fontSize: AppFontSize.body),
      ),
      icon: const Icon(Icons.subtitles_outlined, size: 14),
      label: const Text('从视频提取脚本'),
    );
    if (available) return button;
    // 禁用要说明原因——点不动又不解释的按钮等于坏了
    return Tooltip(
        message: '尚未配置 AI 服务（语音识别与语义分行），无法提取',
        child: button);
  }

  /// 提取进行中/失败的交代条：等待有进度，失败有原因和重试
  Widget _extractBanner() {
    final state = _extract;
    if (state is _ExtractRunning) {
      return Container(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AppColors.accentBlue)),
            const SizedBox(width: AppSpacing.sm),
            Text(state.stage.label,
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: AppSpacing.sm),
          const LinearProgressIndicator(
              minHeight: 2,
              color: AppColors.accentBlue,
              backgroundColor: AppColors.surfaceCard),
        ]),
      );
    }
    if (state is _ExtractFailed) {
      return Container(
        margin: const EdgeInsets.fromLTRB(
            AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, 0),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(state.message,
              style: const TextStyle(
                  fontSize: AppFontSize.body,
                  color: AppColors.red,
                  height: 1.4)),
          const SizedBox(height: AppSpacing.xs),
          Row(children: [
            TextButton(
                onPressed: _extractFromVideo, child: const Text('重试')),
            TextButton(
                onPressed: () => setState(() => _extract = null),
                child: const Text('关闭')),
          ]),
        ]),
      );
    }
    return const SizedBox.shrink();
  }

  /// 空脚本的起步引导（见 start_guide.dart）
  Widget _startGuide() => StartGuide(
        canExtract: ref.watch(scriptTranscriberProvider) != null,
        onExtract: _extractFromVideo,
        onWrite: () => setState(() => _guideDismissed = true),
      );

  /// 预览舞台：竖屏幕布居中、限高——播放器窄而居中，不做顶天立地的黑洞。
  /// 有可播内容时是真播放器 + 传输条；没有时占位说明「还差什么」
  Widget _previewStage() {
    final playable = !_planResult.isEmpty && _videoWidget != null;
    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 560),
              child: AspectRatio(
                aspectRatio: 9 / 16,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.stageBackground,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: AppColors.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: playable
                      ? _videoWidget!
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.play_circle_outline,
                                size: 28,
                                color: AppColors.textTertiary
                                    .withValues(alpha: 0.55)),
                            const SizedBox(height: AppSpacing.sm),
                            const Text('配音与镜头就绪后，在这里试片',
                                style: TextStyle(
                                    fontSize: AppFontSize.caption,
                                    color: AppColors.textTertiary)),
                          ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          // 传输条：可播时活的，不可播时禁用态骨架
          Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              key: const ValueKey('director-preview-play'),
              visualDensity: VisualDensity.compact,
              onPressed: playable ? _togglePreviewPlay : null,
              iconSize: 20,
              icon: Icon(_previewPlaying ? Icons.pause : Icons.play_arrow,
                  color: playable
                      ? AppColors.textPrimary
                      : AppColors.textTertiary.withValues(alpha: 0.4)),
            ),
            const SizedBox(width: AppSpacing.xs),
            ValueListenableBuilder<int>(
              valueListenable: _positionMs,
              builder: (_, ms, _) => Text(
                  '${_mmss(playable ? ms : 0)} / ${_mmss(_planResult.plan.totalMs)}',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: playable
                          ? AppColors.textSecondary
                          : AppColors.textTertiary.withValues(alpha: 0.5),
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ]),
          // 预览可以少几行——人还在编排——但少了哪几行必须点名。
          // 行多时按原因分组汇总，不拿一面墙的橙字糊满中栏
          if (_planResult.skippedLines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Text(
                  _skippedSummary(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.orange,
                      height: 1.5),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  /// 未进预览的交代：≤4 行逐条点名；再多按原因分组（「第 3~29 行还没
  /// 生成配音」比二十七行橙字有用得多）
  String _skippedSummary() {
    final skipped = _planResult.skippedLines;
    if (skipped.length <= 4) {
      return [
        for (final e in skipped.entries) '第 ${e.key + 1} 行未进预览：${e.value}',
      ].join('\n');
    }
    final byReason = <String, List<int>>{};
    for (final e in skipped.entries) {
      (byReason[e.value] ??= []).add(e.key + 1);
    }
    return [
      for (final e in byReason.entries)
        '${_lineNumbers(e.value)} 未进预览：${e.key}',
    ].join('\n');
  }

  static String _lineNumbers(List<int> nums) {
    nums.sort();
    if (nums.length <= 3) return '第 ${nums.join('、')} 行';
    return '第 ${nums.first}~${nums.last} 行等 ${nums.length} 行';
  }

  static String _mmss(int ms) {
    final s = ms ~/ 1000;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _blockedView() => Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('「$_blockedBy」正在处理这个任务',
                style: const TextStyle(
                    fontSize: AppFontSize.title,
                    color: AppColors.textPrimary)),
            const SizedBox(height: AppSpacing.sm),
            const Text('等它结束再进（谁先进谁处理）',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppFontSize.caption)),
            const SizedBox(height: AppSpacing.lg),
            Row(mainAxisSize: MainAxisSize.min, children: [
              OutlinedButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('返回')),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                  onPressed: _forceTakeover, child: const Text('强制接管')),
            ]),
          ]),
        ),
      );
}

/// 导出进度对话框：一段一报，不许点掉——导出中改内容不会进这一版成片
class _ExportProgressDialog extends StatelessWidget {
  final ValueListenable<ScriptExportProgress?> progress;

  const _ExportProgressDialog({required this.progress});

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('正在导出成片'),
          content: ValueListenableBuilder<ScriptExportProgress?>(
            valueListenable: progress,
            builder: (_, value, _) =>
                Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(
                  value: value?.fraction, color: AppColors.accentBlue),
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(value?.step ?? '准备中',
                    style: const TextStyle(
                        fontSize: AppFontSize.body,
                        color: AppColors.textSecondary)),
              ),
            ]),
          ),
        ),
      );
}


/// 参考段小窗：循环播这一句在参考片里的区间。
/// 用独立的 mpv 实例——试听不该动主预览的位置
class _RefClipDialog extends StatefulWidget {
  final String videoPath;
  final int startMs;
  final int endMs;

  const _RefClipDialog(
      {required this.videoPath, required this.startMs, required this.endMs});

  @override
  State<_RefClipDialog> createState() => _RefClipDialogState();
}

class _RefClipDialogState extends State<_RefClipDialog> {
  final MediaKitPlaybackController _player = MediaKitPlaybackController();
  Timer? _looper;

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      await _player.open(widget.videoPath);
      await _player.seekMs(widget.startMs);
      await _player.play();
      // 到区间尾绕回开头（循环看这一句的画面）
      _looper = Timer.periodic(const Duration(milliseconds: 200), (_) async {
        // positionMsStream 是流；轮询当前值最省事——弹窗生命周期很短
      });
      _player.positionMsStream.listen((ms) {
        if (ms >= widget.endMs) {
          unawaited(_player.seekMs(widget.startMs));
        }
      });
    }());
  }

  @override
  void dispose() {
    _looper?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: AppColors.stageBackground,
        child: SizedBox(
          width: 300,
          height: 560,
          child: Column(children: [
            Expanded(child: _player.buildVideoWidget()),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Row(children: [
                Text(
                    '参考 ${(widget.startMs / 1000).toStringAsFixed(1)}s'
                    ' ~ ${(widget.endMs / 1000).toStringAsFixed(1)}s（循环）',
                    style: const TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textSecondary)),
                const Spacer(),
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭')),
              ]),
            ),
          ]),
        ),
      );
}
