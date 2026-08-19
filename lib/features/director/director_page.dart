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
import 'line_inspector.dart';
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

  /// 展开详情的镜头（右栏镜头节；随选中行切换而复位）
  int? _expandedShot;

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
        final src = _mediaCache?.localPathOf(shot.materialId);
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
      final local = _mediaCache?.localPathOf(shot.materialId);
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

  /// 给当前行挑音色。选完只是记下——生成才花钱
  Future<void> _pickVoice() async {
    final line = _doc.lines[_selected];
    // 预填：本行已选的，其次全文档最近一次用过的（连着几行同一个声音是常态）
    final fallback = _doc.lines
        .lastWhere((l) => l.voiceId != null, orElse: () => line)
        .voiceId;
    final picked = await showVoiceSelectDialog(context,
        selected: line.voiceId ?? fallback);
    if (picked == null) return;
    _mutate((d) => d.setVoiceId(_selected, picked));
  }

  /// 显式生成配音：设计稿定死——改字只标黄，点这里才调 API
  Future<void> _generateVoice() async {
    final factory = ref.read(lineVoiceFactoryProvider);
    if (factory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务（语音合成），无法生成配音。')));
      return;
    }
    var line = _doc.lines[_selected];
    if (line.voiceId == null) {
      // 还没选音色：先弹选择器，选完直接接着生成——别让用户点两遍
      await _pickVoice();
      line = _doc.lines[_selected];
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
  Future<void> _findShots() async {
    final line = _doc.lines[_selected];
    // 防撞车：同任务其他行已用的素材要在面板里标出来
    final usedBy = <int, int>{};
    for (var i = 0; i < _doc.lines.length; i++) {
      for (final shot in _doc.lines[i].shots) {
        usedBy.putIfAbsent(shot.materialId, () => i);
      }
    }
    final picked = await showFindShotsSheet(
      context,
      services: ref.read(shotSearchServicesProvider),
      tagger: ref.read(lineTaggerProvider),
      task: _task,
      lineIndex: _selected,
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

  void _updateShots(List<LineShot> shots) {
    final line = _doc.lines[_selected];
    _mutate((d) => d.setShotsById(line.id, shots));
  }

  void _distribute() {
    final line = _doc.lines[_selected];
    final root = ShotAllocation.rootMsOf(line);
    if (root == null) return;
    _updateShots(ShotAllocation.distribute(line.shots, root));
  }

  void _resizeShot(int i, int newAllocMs) {
    final line = _doc.lines[_selected];
    final next = ShotAllocation.resize(line.shots, i, newAllocMs);
    if (next == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('调不动了：相邻镜头已经到底线（每镜最少 0.5 秒）。')));
      return;
    }
    _updateShots(next);
  }

  void _trimShot(int i, int trimStartMs) {
    final line = _doc.lines[_selected];
    final next = [...line.shots];
    next[i] = ShotAllocation.setTrimStart(next[i], trimStartMs);
    _updateShots(next);
  }

  void _speedShot(int i, double speed) {
    final line = _doc.lines[_selected];
    final next = [...line.shots];
    next[i] = ShotAllocation.setSpeed(next[i], speed);
    _updateShots(next);
  }

  Future<void> _togglePlayVoice() async {
    final line = _doc.lines[_selected];
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
        _doc = ScriptDoc(lines);
        _selected = 0;
        _extract = null;
        _guideDismissed = true;
      });
      _flushNow();
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
            // 中：预览（M4 点亮）；空脚本时先当起步引导的舞台
            Expanded(
              child: showGuide ? _startGuide() : _previewStage(),
            ),
            const VerticalDivider(
                width: 1, thickness: 1, color: AppColors.border),
            // 右：当前行工作台（M2 配音 / M3 镜头逐步点亮）
            Container(
              width: 340,
              color: AppColors.surface,
              child: (!showGuide &&
                      _selected >= 0 &&
                      _selected < _doc.lines.length)
                  ? LineInspector(
                      index: _selected,
                      line: _doc.lines[_selected],
                      onManualMsChanged: (ms) =>
                          _mutate((d) => d.setManualMs(_selected, ms)),
                      voiceAvailable:
                          ref.watch(lineVoiceFactoryProvider) != null,
                      generating: _generatingLineIds
                          .contains(_doc.lines[_selected].id),
                      playing: _playingLineId == _doc.lines[_selected].id,
                      onPickVoice: _pickVoice,
                      onSpeechRateChanged: (rate) =>
                          _mutate((d) => d.setSpeechRate(_selected, rate)),
                      onGenerate: _generateVoice,
                      onTogglePlay: _togglePlayVoice,
                      onFindShots: _findShots,
                      onRemoveShot: (i) {
                        final line = _doc.lines[_selected];
                        final next = [...line.shots]..removeAt(i);
                        // 删镜后剩下的镜头按根重新均分——空出的时长不能凭空消失
                        final root = ShotAllocation.rootMsOf(line);
                        _mutate((d) => d.setShotsById(
                            line.id,
                            root == null || next.isEmpty
                                ? next
                                : ShotAllocation.distribute(next, root)));
                        setState(() => _expandedShot = null);
                      },
                      onRemoveTag: (tag) {
                        final line = _doc.lines[_selected];
                        final next =
                            line.tags.where((t) => t != tag).toList();
                        _mutate((d) => d.setTagsById(line.id, next));
                      },
                      expandedShot: _expandedShot,
                      onExpandShot: (i) =>
                          setState(() => _expandedShot = i),
                      onDistribute: _distribute,
                      onResizeShot: _resizeShot,
                      onTrimStart: _trimShot,
                      onShotSpeed: _speedShot,
                      shotStatus: (id) => _mediaCache?.statusOf(id),
                      onRetryDownload: (id) => _mediaCache?.retry(id),
                    )
                  : const SizedBox.shrink(),
            ),
          ]),
        ),
      ]),
    );
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
          // 预览可以少几行——人还在编排——但少了哪几行必须点名
          if (_planResult.skippedLines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Text(
                  [
                    for (final e in _planResult.skippedLines.entries)
                      '第 ${e.key + 1} 行未进预览：${e.value}',
                  ].join('\n'),
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
