import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/ai/tag_dimension.dart';
import '../../core/analysis/scene_detector.dart';
import '../../core/audio/audio_preview.dart';
import '../../core/audio/bgm_plan.dart';
import '../../core/export/export_spec.dart';
import '../../core/audio/voice_catalog.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/script/bgm_rail.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/script_transcriber.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_repository.dart';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ffmpeg/ffprobe_service.dart';
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
import 'preview_subtitle.dart';
import 'tag_picker.dart';
import 'line_board.dart';
import 'script_panel.dart';
import 'start_guide.dart';
import '../../core/subtitle/subtitle_style.dart';
import 'export_readiness.dart';
import 'script_export_dialog.dart';
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

  /// 预览播放位置当前落在的行（右栏跟随高亮）；null = 位置不在任何行里
  int? _previewLineIndex;

  /// 传输条拖动中的位置（ms）；null = 没在拖。拖动中进度以它为准，
  /// 松手才 seek——不然位置流每帧把滑块拽回去
  int? _dragMs;
  final AudioPreview _voicePreview = AudioPreview();

  /// initState 里取好：dispose 阶段还要落一次盘，那时不能再碰 ref
  late final TaskRepository _repo;

  /// 展开详情的镜头：(行下标, 镜头下标)。展开发生在块内，一次一个
  (int, int)? _expandedShot;

  /// 参考段缩略图：行 id → 本地 jpg（抽一帧缓存一帧）
  final Map<String, String> _refThumbs = {};
  final Set<String> _refThumbsRendering = {};

  /// 抽帧失败过的 key：记账后不再重试。没有这本账，build 每帧都会
  /// 重新起一个 ffmpeg（真实发生过：源文件不在时无限重试，测试挂死）
  final Set<String> _refThumbFailed = {};

  /// 取段胶片条的素材帧（materialId → 8 帧路径）。拖窗口时看得见
  /// 取的是哪段画面——纯色条只能靠猜。按素材缓存，算过一次不再抽
  final Map<int, List<String>> _shotFrames = {};
  final Set<int> _shotFramesBusy = {};
  final Set<int> _shotFramesFailed = {};

  /// 抽 24 帧、160px 高：显示端按条宽自适应取 N 帧（格子比例锁素材
  /// 原比例、永不拉伸），24 帧足够覆盖全屏宽度。一条 ffmpeg 命令抽完，
  /// 比逐帧 seek 快数倍
  static const _filmstripFrameCount = 24;

  /// 素材帧的宽高比（宽/高），随帧缓存落盘（meta.txt）；
  /// 取段条按它定格宽，竖屏素材就是竖格
  final Map<int, double> _shotFrameAspect = {};

  /// 确保素材的胶片帧就绪（本地文件在才抽；异步落盘后刷新）
  void _ensureShotFrames(LineShot shot) {
    final id = shot.materialId;
    if (_shotFrames.containsKey(id) ||
        _shotFramesBusy.contains(id) ||
        _shotFramesFailed.contains(id)) {
      return;
    }
    final src = shot.localSource ?? _mediaCache?.localPathOf(id);
    final dataDir = ref.read(dataDirProvider);
    final durMs = shot.durationMs;
    if (src == null || dataDir == null || durMs == null || durMs <= 0) return;
    // v3：24 帧一条命令抽完 + meta 记素材宽高比——目录带版本号，
    // 旧版帧整目录作废（TaskArtifacts 收编按任务清理）
    final dir = Directory(
        p.join(dataDir.path, 'shot_frames', _task.id, '${id}_${durMs}_v3'));
    final expect = [
      for (var i = 1; i <= _filmstripFrameCount; i++)
        p.join(dir.path, 'f${i.toString().padLeft(2, '0')}.jpg'),
    ];
    final metaFile = File(p.join(dir.path, 'meta.txt'));
    if (expect.every((f) => File(f).existsSync()) && metaFile.existsSync()) {
      final aspect = double.tryParse(metaFile.readAsStringSync().trim());
      if (aspect != null && aspect > 0) _shotFrameAspect[id] = aspect;
      _shotFrames[id] = expect;
      return;
    }
    _shotFramesBusy.add(id);
    unawaited(() async {
      try {
        await dir.create(recursive: true);
        // 一条命令均匀抽 N 帧（fps 滤镜），比逐帧 seek 快数倍；
        // 本地源（参考段）先 -ss 切到区间
        final baseMs = shot.localSource != null ? shot.trimStartMs : 0;
        final r = await const ResolvingProcessRunner().call('ffmpeg', [
          '-y', '-v', 'error',
          if (baseMs > 0) ...['-ss', (baseMs / 1000).toStringAsFixed(3)],
          '-t', (durMs / 1000).toStringAsFixed(3),
          '-i', src,
          '-vf',
          'fps=$_filmstripFrameCount/${(durMs / 1000).toStringAsFixed(3)},'
              'scale=-2:160',
          '-frames:v', '$_filmstripFrameCount',
          p.join(dir.path, 'f%02d.jpg'),
        ]);
        if (r.exitCode != 0) throw StateError('ffmpeg exit=${r.exitCode}');
        // fps 滤镜可能少产最后一两帧：缺的用最后一帧补位，别让格子开天窗
        String? last;
        for (final fpath in expect) {
          if (File(fpath).existsSync()) {
            last = fpath;
          } else if (last != null) {
            File(fpath).writeAsBytesSync(File(last).readAsBytesSync());
          }
        }
        if (last == null) throw StateError('一帧都没抽出来');
        // 素材宽高比从 ffprobe 拿，随缓存落盘
        final probe = await const ResolvingProcessRunner().call('ffprobe', [
          '-v', 'error', '-select_streams', 'v:0',
          '-show_entries', 'stream=width,height', '-of', 'csv=p=0:s=x',
          src,
        ]);
        final parts = '${probe.stdout}'.trim().split('x');
        final aspect = parts.length == 2
            ? (double.tryParse(parts[0]) ?? 9) /
                ((double.tryParse(parts[1]) ?? 16) == 0
                    ? 16
                    : double.tryParse(parts[1])!)
            : 9 / 16;
        metaFile.writeAsStringSync(aspect.toStringAsFixed(4));
        if (mounted) {
          setState(() {
            _shotFrameAspect[id] = aspect;
            _shotFrames[id] = expect;
          });
        }
      } catch (e) {
        _shotFramesFailed.add(id);
        AppLog.warn('取段胶片帧抽取失败（素材 $id）：$e');
      } finally {
        _shotFramesBusy.remove(id);
      }
    }());
  }

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

  /// 草片刚做完的庆祝一拍（对勾动效那 1.1 秒），结束即开播
  bool _draftCelebrating = false;

  /// 字幕拖动中的临时位置（bottomRatio）；null = 没在拖。
  /// 拖动实时预览、松手才落盘
  double? _subtitleDragRatio;

  /// 字幕工具条的草稿样式：拖滑杆时实时预览用，松手才 _mutate 落盘
  /// （否则每帧一次撤销记录，⌘Z 要按上百次）
  SubtitleStyle? _styleDraft;
  String? _styleDraftLineId;

  /// 这一行当下生效的字幕样式：草稿 > 行级覆盖 > 全局
  SubtitleStyle _styleOf(ScriptLine line) {
    if (_styleDraftLineId == line.id && _styleDraft != null) {
      return _styleDraft!;
    }
    return line.subtitleOverride ?? _doc.subtitle;
  }

  /// 工具条针对的那一句：正在播的那句优先，否则是选中的那句
  int get _subtitleTargetIndex {
    final i = _previewLineIndex ?? _selected;
    return (i >= 0 && i < _doc.lines.length) ? i : 0;
  }

  /// 草片流水线进度：(阶段名, 当前句摘要, 已完成, 总数)；null = 没在跑。
  /// 这是产品的魔法时刻——提取完一条参考片，几分钟后中央屏幕自动
  /// 播出一版会说话的草片，人从此只做否决和替换
  (String, String, int, int)? _draftProgress;

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
        for (final seg in _doc.bgmSegments) {
          if (seg.material.id == id) return fetch(seg.material);
        }
        throw StateError('这首配乐已经不在方案里了');
      },
      cacheDir: Directory(p.join(dataDir.path, 'bgm_cache')),
    );
  }

  void _pinBgm() {
    final ids = {for (final seg in _doc.bgmSegments) seg.material.id};
    if (ids.isNotEmpty) _bgmCache?.pinAll(ids);
  }

  // ---- 配乐（分段在右栏色带上切；这里只有换曲/音量的动作）----

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
      if (!mounted) return;
      _positionMs.value = ms;
      _syncPreviewLine(ms);
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
    },
        bgmPathOf: (id) => _bgmCache?.localPathOf(id),
        voiceOk: (path) => File(path).existsSync());
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
      // 开播前停掉分镜卡/配音试听——同时只有一个东西在响
      _stopInline();
      await _voicePreview.stop();
      if (_playingLineId != null) setState(() => _playingLineId = null);
      await playback.play();
    }
  }

  /// 播放位置落在哪一行，右栏就点亮哪一行（预览是主角，行块跟着它走）。
  /// 只在换行时 setState——位置流每帧都来，不能每帧重建行带板
  void _syncPreviewLine(int ms) {
    int? current;
    var bestStart = -1;
    for (final e in _planResult.lineStarts.entries) {
      if (e.value <= ms && e.value > bestStart) {
        bestStart = e.value;
        current = e.key;
      }
    }
    if (current == _previewLineIndex) return;
    final previous = _previewLineIndex;
    setState(() => _previewLineIndex = current);
    // 渐进换行由行块自己 ensureVisible；大跳（拖进度条）时目标行块
    // 可能还没被列表构建出来，先按比例粗滚过去让它构建
    if (current != null && (previous == null || (current - previous).abs() > 2)) {
      _scrollBoardNear(current);
    }
  }

  void _scrollBoardNear(int index) {
    if (!_boardScroll.hasClients || _doc.lines.isEmpty) return;
    final pos = _boardScroll.position;
    final target = ((index / _doc.lines.length) * pos.maxScrollExtent)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    unawaited(_boardScroll.animateTo(target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic));
  }

  /// 传输条拖动定位：拖到哪就从哪继续（拖动中不被位置流打架，
  /// 见 _transportBar 的本地拖动态）
  Future<void> _seekPreview(int ms) async {
    await _playback?.seekMs(ms);
    _positionMs.value = ms;
    _syncPreviewLine(ms);
  }

  // ---- 导出 ----

  bool _exporting = false;

  /// 上次用的导出规格（同一个任务里连着导几版时不用重选）
  ExportSpec _exportSpec = ExportSpec.standard;
  final ValueNotifier<ScriptExportProgress?> _exportProgress =
      ValueNotifier(null);

  /// 导出前把素材补齐：**人已经点了导出，意图很明确**——还在下的就等它
  /// 下完（等待写进进度条），只有真下不下来才中断。把人赶回去自己猜
  /// 「下完了没有」不是商业软件该有的样子。
  ///
  /// 返回下不下来的那些（名字 + 原因）；空列表 = 可以开导了。
  Future<List<MediaBlocked>> _prepareMedia() async {
    // 先确保都在队列里（老方案打开后可能还没排过队）
    _pinAllShots();
    _pinBgm();
    final shotIds = <int, String>{};
    for (final line in _doc.lines) {
      for (final shot in line.shots) {
        if (shot.localSource != null) continue; // 参考段用的是原片，不走缓存
        shotIds[shot.materialId] = shot.name;
      }
    }
    final bgmIds = <int, String>{
      for (final seg in _doc.bgmSegments) seg.material.id: seg.material.name,
    };
    final needs = <MediaNeed>[
      for (final e in shotIds.entries) (id: e.key, name: e.value, isBgm: false),
      for (final e in bgmIds.entries) (id: e.key, name: e.value, isBgm: true),
    ];
    if (needs.isEmpty) return const [];
    final deadline = DateTime.now().add(const Duration(minutes: 20));
    while (true) {
      if (!mounted) return const [];
      final r = checkMedia(
        needs,
        statusOf: (n) =>
            (n.isBgm ? _bgmCache : _mediaCache)?.statusOf(n.id),
        failureOf: (n) =>
            (n.isBgm ? _bgmCache : _mediaCache)?.failureOf(n.id),
      );
      if (r.failed.isNotEmpty) return r.failed;
      if (r.canExport) return const [];
      if (DateTime.now().isAfter(deadline)) {
        return [
          (
            id: -1,
            name: '还有 ${r.pending} 项',
            reason: '下载迟迟没有完成（已等 20 分钟），请检查网络后重试',
            isBgm: false
          )
        ];
      }
      // 等待也要有交代：进度条上写清准备到第几项
      _exportProgress.value = ScriptExportProgress(
          '正在准备素材 ${r.ready}/${r.total}', r.ready / r.total * 0.06);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// 素材没齐时的出路：**「知道了」不是操作**。给重试；如果卡住的
  /// 全是配乐，还可以把这几段配乐撤掉直接出片（画面和口播不受影响）
  Future<String?> _askMediaBlocked(List<MediaBlocked> failed) async {
    final allBgm = failed.every((f) => f.isBgm) && failed.first.id > 0;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('素材还没齐'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final f in failed.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('· ${f.isBgm ? '配乐' : '素材'}「${f.name}」：${f.reason}',
                    style: const TextStyle(fontSize: AppFontSize.caption)),
              ),
            if (failed.length > 5)
              Text('…还有 ${failed.length - 5} 项',
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('先不导')),
          if (allBgm)
            TextButton(
                key: const ValueKey('export-drop-bgm'),
                onPressed: () => Navigator.of(context).pop('drop-bgm'),
                child: const Text('去掉这几段配乐继续导出')),
          FilledButton(
              key: const ValueKey('export-retry-download'),
              onPressed: () => Navigator.of(context).pop('retry'),
              child: const Text('重试下载')),
        ],
      ),
    );
  }

  Future<void> _exportScript() async {
    final cache = _mediaCache;
    final dataDir = ref.read(dataDirProvider);
    if (cache == null || dataDir == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('当前环境没有素材下载器，无法导出。')));
      return;
    }
    _flushNow();
    // 规格该选还得选（与其他模块同一套面板）；记住上次的选择
    final spec = await showScriptExportDialog(
      context,
      initial: _exportSpec,
      durationMs: _planResult.plan.totalMs,
      lineCount: _doc.lines.where((l) => l.shots.isNotEmpty).length,
    );
    if (spec == null || !mounted) return;
    setState(() {
      _exportSpec = spec;
      _exporting = true;
    });
    _exportProgress.value = const ScriptExportProgress('准备中', 0);
    // 模态进度：导出中不许再改内容，改了也不会进这一版成片
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportProgressDialog(progress: _exportProgress),
    ));
    // 先把素材补齐（还在下就等，进度写在条上）；下不下来才中断并给出路
    while (true) {
      final blocked = await _prepareMedia();
      if (!mounted) return;
      if (blocked.isEmpty) break;
      Navigator.of(context, rootNavigator: true).pop();
      final choice = await _askMediaBlocked(blocked);
      if (!mounted) return;
      if (choice == null) {
        setState(() => _exporting = false);
        return;
      }
      if (choice == 'drop-bgm') {
        final drop = {for (final f in blocked) f.id};
        _mutate((d) => d.withBgmSegments([
              for (final seg in d.bgmSegments)
                if (!drop.contains(seg.material.id)) seg,
            ]));
        _flushNow();
        _pinBgm();
      } else {
        for (final f in blocked) {
          (f.isBgm ? _bgmCache : _mediaCache)?.retry(f.id);
        }
      }
      _exportProgress.value = const ScriptExportProgress('准备中', 0);
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ExportProgressDialog(progress: _exportProgress),
      ));
    }
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
        '${stamp.minute.toString().padLeft(2, '0')}.${spec.format.name}';
    try {
      final out = await runner.export(
        doc: _doc,
        outPath: p.join(outDir, name),
        spec: spec,
        bgmPathOf: (id) => _bgmCache?.localPathOf(id),
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
    unawaited(_backfillMeasuredDurations());
  }

  /// 正在量的，避免同一条素材反复量
  final Set<int> _measuring = {};

  /// 素材落地就量一次**真实时长**回填。
  ///
  /// 时长原本靠对着签名地址跑 ffprobe 探测，网络一抖就探不到；探不到就是
  /// null，而 null 在分配里被当成「无限长」——于是 1.2 秒的素材能被分到
  /// 6 秒的坑位，预览与成片两头出错（真机踩过）。文件都在本地了，量一下
  /// 几十毫秒的事，没有必要继续猜
  Future<void> _backfillMeasuredDurations() async {
    final cache = _mediaCache;
    if (cache == null) return;
    final todo = <int, String>{};
    for (final line in _doc.lines) {
      for (final shot in line.shots) {
        if (shot.localSource != null || shot.durationMs != null) continue;
        if (_measuring.contains(shot.materialId)) continue;
        final path = cache.localPathOf(shot.materialId);
        if (path != null) todo[shot.materialId] = path;
      }
    }
    if (todo.isEmpty) return;
    _measuring.addAll(todo.keys);
    for (final e in todo.entries) {
      try {
        final info = await FfprobeService().probe(e.value);
        final ms = info.duration.inMilliseconds;
        if (ms > 0 && mounted) {
          _mutate((d) => d.withMeasuredDuration(e.key, ms));
        }
      } catch (err) {
        AppLog.warn('素材 ${e.key} 实测时长失败：$err');
      } finally {
        _measuring.remove(e.key);
      }
    }
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
    _replayDebounce?.cancel();
    unawaited(_inlineLoop?.cancel());
    unawaited(_inlinePosSub?.cancel());
    _inlinePositionMs.dispose();
    unawaited(_inlinePlayer?.dispose());
    unawaited(_inlineAudio?.dispose());
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
    final voicedCount =
        _doc.lines.where((l) => l.type == ScriptLineType.voiced).length;
    final picked = await showVoiceSelectDialog(context,
        selected: line.voiceId ?? fallback, allowApplyAll: voicedCount > 1);
    if (picked == null || !mounted) return;
    final (voiceId, applyAll) = picked;
    if (!applyAll) {
      _mutate((d) => d.setVoiceId(index, voiceId));
      return;
    }
    // 整片换声：一次改完；旧配音自然标黄，「生成草片」一键全部重配
    _mutate((d) {
      var next = d;
      for (var i = 0; i < next.lines.length; i++) {
        if (next.lines[i].type == ScriptLineType.voiced) {
          next = next.setVoiceId(i, voiceId);
        }
      }
      return next;
    });
    final name = VoiceCatalog.byId(voiceId)?.ref.name ?? voiceId;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('整片音色换成「$name」了——点「生成草片」一键全部重新配音。')));
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
    final ok = await _generateVoiceCore(line.id, line.voiceId!);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('配音生成失败，请稍后重试。')));
    }
  }

  /// 配音生成内核（静默版）：草片流水线与单行按钮共用。
  /// 成功返回 true；失败只留日志，由调用方决定怎么告知
  Future<bool> _generateVoiceCore(String lineId, String voiceId) async {
    final factory = ref.read(lineVoiceFactoryProvider);
    if (factory == null) return false;
    final line = _doc.lines.firstWhere((l) => l.id == lineId);
    setState(() => _generatingLineIds.add(lineId));
    try {
      final service = factory(_task);
      final vo = await service.generate(
        lineId: lineId,
        text: line.text,
        voiceId: voiceId,
        speechRate: line.speechRate,
      );
      if (!mounted) return false;
      _mutate((d) => d.setVoiceoverById(lineId, vo));
      // 配音时长是这一行时间轴的根：根变了，镜头的时长分配跟着重算
      final updated = _doc.lines.firstWhere((l) => l.id == lineId);
      if (updated.shots.isNotEmpty) {
        _mutate((d) => d.setShotsById(
            lineId,
            ShotAllocation.fillBySlowdown(
                ShotAllocation.distribute(updated.shots, vo.durationMs),
                vo.durationMs)));
      }
      _flushNow();
      // 旧配音**不再立即删**：⌘Z 撤销可能把数据回滚到旧文件上，
      // 立即删就撤成死链（真机发生过：行 2 台词整段无声）。
      // 不被任何行引用的旧 mp3 由任务清理兜底回收
      return true;
    } catch (e) {
      AppLog.warn('配音生成失败（line=$lineId）：$e');
      return false;
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
      // 参考原子条的数据：原子首帧缩略图 + 原片路径（直接用原片这段）
      refThumbOf: (segIndex) {
        _ensureRefThumb(line, segIndex);
        return _refThumbs['${line.id}_$segIndex'];
      },
      refVideoPath: _refVideoOf(line),
      tagRefShot: (segIndex) => _tagRefShot(line.id, segIndex),
      // 参考没切过视觉镜头：在面板里切（面板开着 loading），切完把
      // 新的行回给面板——不让人看旧数据、也不必关掉重开
      prepareRef: () async {
        await _ensureRefCuts(line.id);
        return _doc.lines.where((l) => l.id == line.id).firstOrNull;
      },
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

  /// 这一句的参考还没切过视觉镜头时，**就地切一次**（只切这句的区间，
  /// 几秒；老任务提取时没切出切点，不必为此重新提取整片）。
  /// 切点存回行上，之后即开即用；切失败不挡路——退回整段一镜
  Future<void> _ensureRefCuts(String lineId) async {
    final line = _doc.lines.where((l) => l.id == lineId).firstOrNull;
    final ref = line?.reference;
    final video = line == null ? null : _refVideoOf(line);
    if (line == null || ref == null || video == null) return;
    if (ref.cuts.isNotEmpty || _refCutting.contains(lineId)) return;
    if (!File(video).existsSync()) return;
    _refCutting.add(lineId);
    try {
      // 只切这一句的区间：先裁一段临时片再检测，比整片检测快得多
      final dataDir = this.ref.read(dataDirProvider);
      final tmp = File(p.join(
          dataDir?.path ?? Directory.systemTemp.path,
          'script_refs',
          _task.id,
          'cut_${line.id}.mp4'));
      await tmp.parent.create(recursive: true);
      final cut = await const ResolvingProcessRunner().call('ffmpeg', [
        '-y', '-v', 'error',
        '-ss', (ref.startMs / 1000).toStringAsFixed(3),
        '-t', (ref.durationMs / 1000).toStringAsFixed(3),
        '-i', video,
        '-an', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '28',
        tmp.path,
      ]);
      if (cut.exitCode != 0) throw StateError('裁参考段失败');
      final rel = await SceneDetector(run: const ResolvingProcessRunner().call)
          .detect(tmp.path);
      try {
        tmp.deleteSync();
      } catch (_) {}
      // 相对坐标 → 原片坐标；丢掉太靠边的切点（<400ms 的碎段没价值）
      final abs = [
        for (final ms in rel)
          if (ms > 400 && ms < ref.durationMs - 400) ref.startMs + ms,
      ];
      if (abs.isEmpty || !mounted) return;
      _mutate((d) => d.setReferenceById(line.id, ref.withCuts(abs)));
      AppLog.info('参考就地切分（line=$lineId）：${abs.length} 个切点');
    } catch (e) {
      AppLog.warn('参考就地切分失败（line=$lineId，退回整段一镜）：$e');
    } finally {
      _refCutting.remove(lineId);
    }
  }

  final Set<String> _refCutting = {};

  /// 给参考视觉镜头按需打标：抽三帧（头/中/尾）→ ShotTagger 一次出
  /// 标签 + 画面描述 → 缓存回行上（切点变了自动失效）。
  /// 打标是花钱的一步，所以**只在点选那一镜时打这一镜**，不整片预打
  Future<RefShotMeta?> _tagRefShot(String lineId, int segIndex) async {
    final line = _doc.lines.where((l) => l.id == lineId).firstOrNull;
    final ref = line?.reference;
    final video = line == null ? null : _refVideoOf(line);
    final tagger = ref == null ? null : this.ref.read(refShotTaggerProvider);
    final dataDir = this.ref.read(dataDirProvider);
    if (line == null || ref == null || video == null || tagger == null ||
        dataDir == null) {
      return null;
    }
    final segs = ref.segments;
    if (segIndex < 0 || segIndex >= segs.length) return null;
    final (segStart, segEnd) = segs[segIndex];
    try {
      // 三帧：头/中/尾——单帧看不出镜头里在发生什么（U 层实测）
      final dir = Directory(
          p.join(dataDir.path, 'script_refs', _task.id, 'tag_${line.id}_$segIndex'));
      await dir.create(recursive: true);
      final frames = <List<int>>[];
      String? firstFrame;
      for (final (i, at) in [
        (0, segStart + 120),
        (1, (segStart + segEnd) ~/ 2),
        (2, segEnd - 120),
      ]) {
        final out = p.join(dir.path, 'f$i.jpg');
        final r = await const ResolvingProcessRunner().call('ffmpeg', [
          '-y', '-v', 'error',
          '-ss', (at / 1000).toStringAsFixed(3),
          '-i', video,
          '-frames:v', '1',
          '-vf', 'scale=-2:480',
          out,
        ]);
        if (r.exitCode == 0 && File(out).existsSync()) {
          frames.add(File(out).readAsBytesSync());
          firstFrame ??= out;
        }
      }
      if (frames.isEmpty) return null;
      // 视觉镜头层用**视觉镜头标签组**的词表（与单元层的话术标签不同）
      final groups = _task.shotTagGroups.isNotEmpty
          ? _task.shotTagGroups
          : _task.unitTagGroups;
      final vocab = <TagDimension>[];
      try {
        final all = await this.ref.read(shotSearchServicesProvider).tags.listGroups();
        for (final g in groups) {
          final hit = all.where((x) => x.id == g.id).firstOrNull;
          if (hit != null && hit.tags.isNotEmpty) {
            vocab.add(TagDimension(name: hit.name, vocabulary: hit.tags));
          }
        }
      } catch (e) {
        AppLog.warn('参考镜头打标拉词表失败（只出画面描述）：$e');
      }
      final understanding = await tagger.understand(
        frames: frames,
        dimensions: vocab,
        constraint: _task.shotTagPrompt.isEmpty ? null : _task.shotTagPrompt,
      );
      final meta = RefShotMeta(
        startMs: segStart,
        description: understanding.description ?? '',
        tags: understanding.tags,
        framePath: firstFrame,
      );
      if (!mounted) return meta;
      _mutate((d) => d.setReferenceById(line.id, ref.withShotMeta(meta)));
      return meta;
    } catch (e) {
      AppLog.warn('参考镜头打标失败（line=$lineId seg=$segIndex）：$e');
      return null;
    }
  }

  /// 从这一句开始换一首（在轨上切一刀）：切开后先继承上一段的曲子，
  /// 紧接着弹选曲——多数时候你就是要给后半段换个曲子
  Future<void> _bgmSplitAt(int lineIndex) async {
    final rail = bgmRail(_doc.bgmSegments, _doc.lines.length);
    final next = splitRailAt(rail, lineIndex);
    if (identical(next, rail)) return;
    _mutate((d) => d.withBgmSegments(railToSegments(next)));
    final segIndex = next.indexWhere((s) => s.startLine == lineIndex);
    if (segIndex >= 0) await _bgmEditSegment(segIndex);
  }

  /// 点段首色带：给这一段换曲 / 调音量 / 设为不要配乐 / 与上一段合并
  Future<void> _bgmEditSegment(int segIndex) async {
    final rail = bgmRail(_doc.bgmSegments, _doc.lines.length);
    if (segIndex < 0 || segIndex >= rail.length) return;
    final seg = rail[segIndex];
    // 这一段有多长：按已就绪行的时长累加（说清「这段要放多久的曲子」）
    var rangeMs = 0;
    for (var i = seg.startLine; i <= seg.endLine && i < _doc.lines.length; i++) {
      final root = ShotAllocation.rootMsOf(_doc.lines[i]);
      rangeMs += root ?? 0;
    }
    final choice = await showBgmPicker(
      context,
      rangeMs: rangeMs,
      rangeLabel: '第 ${seg.startLine + 1}~${seg.endLine + 1} 句',
      canClear: true,
      projectIds: [if (_task.project != null) _task.project!.id],
      initialVolume: seg.volume,
      initialMaterials: [if (seg.material != null) seg.material!],
    );
    if (choice == null || !mounted) return;
    final updated = switch (choice) {
      BgmPicked(materials: final ms, volume: final v) => seg.copyWith(
          material: ms.isEmpty ? null : ms.first, volume: v),
      _ => seg.copyWith(material: null),
    };
    final next = [
      for (var i = 0; i < rail.length; i++)
        if (i == segIndex) updated else rail[i],
    ];
    _mutate((d) => d.withBgmSegments(railToSegments(next)));
    _pinBgm();
  }

  /// 一句短提示（打轴这类高频操作要立刻有交代，不许点了没反应）
  void _toast(String message) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context)..clearSnackBars();
    m.showSnackBar(SnackBar(
        content: Text(message), duration: const Duration(seconds: 2)));
  }

  /// 打轴：正在原位播这一镜时，在**当前播放位置**换一屏。
  /// 十秒六句话，听一遍点五下就切完了——比数字数快。
  /// 切点只记「从哪个字另起一屏」，镜头时长怎么改都不跑偏
  void _cutSubtitleHere(int index, int j) {
    final line = _doc.lines[index];
    if (j < 0 || j >= line.shots.length) return;
    final player = _inlinePlayer;
    if (player == null || _inlineKey != 'shot_${line.id}_$j') {
      _toast('先播这一镜，听到该换屏的地方再点。');
      return;
    }
    // 播放位置（素材坐标）→ 这一镜内已经走了多久 → 行时间轴（成片时间）
    final shot = line.shots[j];
    final playedMs =
        ((player.positionMs - shot.trimStartMs) / shot.speed).round();
    final atMs = _lineShotStart(line, j) +
        playedMs.clamp(0, shot.allocMs ?? 0);
    final chars = _styleOf(line).maxCharsPerScreen;
    final before = line.subtitleScreensAt(maxChars: chars).length;
    final next = line.cutSubtitleAt(atMs, maxChars: chars);
    if (next.subtitleScreensAt(maxChars: chars).length == before) {
      // 切不动要说清为什么（这一刻正说着这一屏的第一个字 / 没有词级时间戳）
      _toast(line.voiceover?.words.isEmpty ?? true
          ? '这句配音没有逐字时间，重新生成配音后才能打轴。'
          : '这里已经是一屏的开头了。');
      return;
    }
    _mutate((d) => d.cutScreenById(line.id, atMs, maxChars: chars));
    _toast('已在 ${(atMs / 1000).toStringAsFixed(1)}s 换屏。');
  }

  /// 这一镜在行时间轴上的起点（成片时间）
  int _lineShotStart(ScriptLine line, int j) {
    var start = 0;
    for (var i = 0; i < j && i < line.shots.length; i++) {
      start += line.shots[i].allocMs ?? 0;
    }
    return start;
  }

  /// 改行标签：从妙啊标签体系里搜索、点选、替换（不只是删）
  Future<void> _editTags(int index) async {
    final line = _doc.lines[index];
    final picked = await showTagPicker(
      context,
      tags: ref.read(shotSearchServicesProvider).tags,
      selected: line.tags,
      preferredGroupIds: {for (final g in _task.unitTagGroups) g.id},
    );
    if (picked == null || !mounted) return;
    _mutate(
        (d) => d.setTagsById(line.id, [for (final t in picked) t.name]));
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

  /// 素材偏短分不满行时长：放慢镜头把整行充满（分镜可加速可放慢，
  /// 短了就慢放，别把「素材不够长」留给人发愁）
  void _slowFill(int index) {
    final line = _doc.lines[index];
    final root = ShotAllocation.rootMsOf(line);
    if (root == null) return;
    final filled = ShotAllocation.fillBySlowdown(line.shots, root);
    if (identical(filled, line.shots)) return;
    _updateShots(index, filled);
    final left = ShotAllocation.shortfallMs(filled, root);
    if (left > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('放慢到 0.5x 还差 ${(left / 1000).toStringAsFixed(1)} 秒'
              '——这条素材实在太短，换一条或再加一镜吧。')));
    }
  }

  /// 上次弹「到底线」提示的时刻：拖拽每帧都会触发失败，提示要节流
  /// ——不然一次拖拽攒下一队列 SnackBar，松手后还在连环弹（真机反馈）
  DateTime _lastResizeHint = DateTime.fromMillisecondsSinceEpoch(0);

  void _resizeShot(int index, int j, int newAllocMs) {
    final line = _doc.lines[index];
    final next = ShotAllocation.resize(line.shots, j, newAllocMs);
    if (next == null) {
      final now = DateTime.now();
      if (now.difference(_lastResizeHint) > const Duration(seconds: 3)) {
        _lastResizeHint = now;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(
              duration: Duration(seconds: 2),
              content: Text('调不动了：相邻镜头已经到底线（每镜最少 0.5 秒）。')));
      }
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
    if (_refThumbs.containsKey(key) ||
        _refThumbsRendering.contains(key) ||
        _refThumbFailed.contains(key)) {
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
        } else {
          _refThumbFailed.add(key);
        }
      } catch (e) {
        _refThumbFailed.add(key);
        AppLog.warn('参考缩略图抽帧失败（$key）：$e');
      } finally {
        _refThumbsRendering.remove(key);
      }
    }());
  }

  // ---- 原位播放（卡片就地播，不弹窗）----

  /// 共享的原位播放器：同时只有一张卡在播，谁在播就挂到谁的卡上
  MediaKitPlaybackController? _inlinePlayer;

  /// 原位播放的配音伴奏（独立实例同步播配音段——外挂音轨那条 API
  /// 在 macOS 上不工作，主预览的口播轨也是独立实例，照抄已验证模式）
  MediaKitPlaybackController? _inlineAudio;
  Widget? _inlineVideo;

  /// 正在原位播放的卡：'ref_行id' 或 'shot_行id_镜下标'；null = 没在播
  String? _inlineKey;
  StreamSubscription<bool>? _inlineLoop;

  /// 原位播放的位置（素材坐标）——卡上叠的字幕跟着它换屏。
  /// 用 ValueNotifier：只重建那一块字，不带着整块板子每秒刷几次
  final ValueNotifier<int> _inlinePositionMs = ValueNotifier<int>(0);
  StreamSubscription<int>? _inlinePosSub;

  /// 原位播放一段：再点同一张卡 = 停。开播前停掉其他一切声源
  /// （主预览、配音试听）——同时只有一个东西在响。
  /// [audioPath] 非空时用独立实例同步播配音的 [audioStartMs, audioEndMs)
  /// 段（分镜素材多为无声，成片里这一镜配的就是这段配音）
  Future<void> _playInline(
      String key, String path, int startMs, int endMs,
      {double rate = 1.0,
      String? audioPath,
      int audioStartMs = 0,
      int audioEndMs = 0}) async {
    if (_inlineKey == key) {
      _stopInline();
      return;
    }
    if (!File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('这段视频已不在本地，回来后才能播放。')));
      return;
    }
    await _stopAllPlayback(exceptInline: true);
    await _inlineLoop?.cancel();
    _inlineLoop = null;
    final player = _inlinePlayer ??= MediaKitPlaybackController();
    _inlineVideo ??= player.buildVideoWidget();
    setState(() => _inlineKey = key);
    await _inlinePosSub?.cancel();
    _inlinePosSub =
        player.positionMsStream.listen((ms) => _inlinePositionMs.value = ms);
    await player.open(path);
    await player.waitUntilLoaded();
    if (!mounted || _inlineKey != key) return;
    await player.setMuted(false);
    await player.player.setRate(rate);
    final withVoice =
        audioPath != null && File(audioPath).existsSync() && audioEndMs > 0;
    if (withVoice) {
      final audio = _inlineAudio ??= MediaKitPlaybackController();
      await audio.open(audioPath);
      await audio.waitUntilLoaded();
      if (!mounted || _inlineKey != key) return;
      await audio.setMuted(false);
    }
    Future<void> playSeg() async {
      // 画面与配音各自 playRange，同时起跑（几十毫秒内的相差
      // 预览无感；主预览的多轨同样是双实例同步）
      if (withVoice) {
        unawaited(_inlineAudio!.playRange(audioStartMs, audioEndMs, 30));
      }
      final ok = await player.playRange(startMs, endMs, 30);
      if (!ok) {
        await player.seekMs(startMs);
        await player.play();
      }
    }

    await playSeg();
    // 播一次就停（用户定的：不要循环）——段尾自然停住后清态，
    // 按钮从 ⏹ 复位回 ▶。**只认段尾**：中途因落盘/重建产生的瞬时
    // 暂停不该把播放判成结束
    _inlineLoop = player.playingStream.listen((playing) {
      if (playing || !mounted || _inlineKey != key) return;
      if (player.positionMs >= endMs - 250) _stopInline();
    });
  }

  /// 重播某一镜（取段/时长刚调完，听调整后的效果）——
  /// 与点 ▶ 的 toggle 不同，这里无论在不在播都重新来一遍
  Future<void> _replayShotInline(int index, int j) async {
    _stopInline();
    await _playShotInline(index, j);
  }

  /// 取段调整后的重播防抖。
  ///
  /// **松手先别播**：立刻播放的是改动落定前的旧区间，紧接着落盘与
  /// 预览重建又把它打断——「播一下就停」的顿挫（真机反馈）。
  /// 这里等改动落定（预览重建防抖 600ms + 余量）再播一次新区间；
  /// 期间继续拖就重新计时，只在最后一次调整后播一遍
  Timer? _replayDebounce;

  void _scheduleReplayShot(int index, int j) {
    _replayDebounce?.cancel();
    _stopInline();
    _replayDebounce = Timer(const Duration(milliseconds: 780), () {
      if (!mounted) return;
      unawaited(_replayShotInline(index, j));
    });
  }

  void _stopInline() {
    unawaited(_inlineLoop?.cancel());
    _inlineLoop = null;
    unawaited(_inlinePosSub?.cancel());
    _inlinePosSub = null;
    unawaited(_inlinePlayer?.pause());
    unawaited(_inlineAudio?.pause());
    if (mounted && _inlineKey != null) setState(() => _inlineKey = null);
  }

  /// 停掉一切声源（互斥的地基）：任何播放动作开始前先调它——
  /// 分镜在播时点主预览、点配音试听，前面的必须停
  Future<void> _stopAllPlayback({bool exceptInline = false}) async {
    await _playback?.pause();
    await _voicePreview.stop();
    if (_playingLineId != null && mounted) {
      setState(() => _playingLineId = null);
    }
    if (!exceptInline) _stopInline();
  }

  /// 播放参考：**原位**循环播（在参考卡自己的位置上，不弹窗）。
  /// [segIndex] >=0 播该参考分镜（原子）区间，传负数播整段（分子）
  Future<void> _playReference(int index, int segIndex) async {
    final line = _doc.lines[index];
    final ref = line.reference;
    final video = _refVideoOf(line);
    if (ref == null || video == null) return;
    final segments = ref.segments;
    final (startMs, endMs) = segIndex >= 0 && segIndex < segments.length
        ? segments[segIndex]
        : (ref.startMs, ref.endMs);
    await _playInline('ref_${line.id}', video, startMs, endMs);
  }

  /// 原位播放一个镜头——**成片里这一镜的样子**：画面（变速镜头优先用
  /// 渲好的对齐切片）+ 这一句配音的对应段（外挂对齐；分镜素材本身
  /// 多是无声的）。没配音的行退回素材原声按倍率播
  Future<void> _playShotInline(int index, int j) async {
    final line = _doc.lines[index];
    if (j < 0 || j >= line.shots.length) return;
    final shot = line.shots[j];
    final src =
        shot.localSource ?? _mediaCache?.localPathOf(shot.materialId);
    if (src == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('素材还没下载好，稍等一下再播。')));
      return;
    }
    // 该镜在行时间轴上的起点 = 前面镜头的 alloc 累计（配音同轴）
    var segStartMs = 0;
    for (var i = 0; i < j; i++) {
      segStartMs += line.shots[i].allocMs ?? 0;
    }
    final vo = line.voiceover;
    final alloc = shot.allocMs ?? shot.durationMs ?? 3000;
    // 变速镜头优先播渲好的对齐切片（时长 = alloc、配音同速）；
    // 切片还没渲好就退素材原速近似
    final clip = shot.speed != 1.0 ? _speedClips[_clipKey(shot)] : null;
    final String path;
    final int start;
    final int end;
    double rate = 1.0;
    if (clip != null) {
      path = clip;
      start = 0;
      end = alloc;
    } else {
      path = src;
      start = shot.trimStartMs;
      end = start +
          (shot.consumedSourceMs > 0
              ? shot.consumedSourceMs
              : (shot.durationMs ?? 3000));
      // **画面永远按这一镜自己的倍速播**：0.5x 就慢放，1.25 秒素材
      // 正好铺满 2.5 秒——与配音天然对齐，不需要任何补偿
      rate = shot.speed;
    }
    await _playInline('shot_${line.id}_$j', path, start, end,
        rate: rate,
        audioPath: vo?.audioPath,
        // 配音段 = 该镜在行时间轴上的区间（配音与行同轴）
        audioStartMs: segStartMs,
        audioEndMs: segStartMs + alloc);
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
  /// 给这一句传参考：**视频或图片都行，只能有一个**（再传就是替换）。
  ///
  /// 视频：≤15 秒（一个台词语义单元本来就不该更长），传完把它当这一句的
  /// 参考做该做的事——跑 ASR（**只用于展示**这段说了什么，不回填脚本、
  /// 不参与检索）+ 视觉切分（切成 N 个视觉镜头，供添加分镜时按画面找）。
  /// 图片：它天然就是「首帧」，只给视觉镜头层当查询帧
  Future<void> _uploadReference(int index) async {
    final line = _doc.lines[index];
    final path = await ref.read(refFilePickerProvider)();
    if (path == null || !mounted) return;
    if (line.reference != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('换掉这一句的参考？'),
          content: const Text('旧参考的切分与画面标注会一起作废；'
              '已经用参考画面做成的镜头保留不动。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('算了')),
            FilledButton(
                key: const ValueKey('ref-replace-ok'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('换')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final isImage = const ['.jpg', '.jpeg', '.png', '.webp']
        .any((e) => path.toLowerCase().endsWith(e));
    if (isImage) {
      // 参考图：没有时长与台词，用一个象征性的区间占位
      _mutate((d) => d.setReferenceById(
          line.id, LineRef(startMs: 0, endMs: 1, imagePath: path)));
      _flushNow();
      return;
    }
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
    if (durationMs > _maxRefMs) {
      // 不静默截断——截了用户会以为软件吃了他的东西
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('这段有 ${(durationMs / 1000).toStringAsFixed(1)} 秒，'
                '一个台词语义单元的参考不该超过 ${_maxRefMs ~/ 1000} 秒——'
                '裁一下再传。')));
      }
      return;
    }
    _mutate((d) => d.setReferenceById(
        line.id, LineRef(startMs: 0, endMs: durationMs, videoPath: path)));
    _flushNow();
    // 后台把该做的事做掉：ASR（只展示）+ 视觉切分（供按画面找镜头）
    unawaited(_prepareUploadedRef(line.id));
  }

  /// 手动传的参考视频上限：一个台词语义单元本来就不该超过 15 秒
  static const int _maxRefMs = 15000;

  /// 手动传的参考视频跑一遍它该做的事：ASR（展示用）+ 视觉切分
  Future<void> _prepareUploadedRef(String lineId) async {
    await _ensureRefCuts(lineId);
    if (!mounted) return;
    final line = _doc.lines.where((l) => l.id == lineId).firstOrNull;
    final ref0 = line?.reference;
    final video = line == null ? null : _refVideoOf(line);
    final transcriber = ref.read(scriptTranscriberProvider);
    if (line == null || ref0 == null || video == null || transcriber == null) {
      return;
    }
    if (ref0.words.isNotEmpty) return;
    try {
      final sentences = await transcriber.transcribeOnly(video);
      if (!mounted) return;
      final words = [
        for (final s in sentences)
          for (final w in s.words)
            VoiceWord(text: w.text, startMs: w.startMs, endMs: w.endMs),
      ];
      if (words.isEmpty) return;
      final cur = _doc.lines.where((l) => l.id == lineId).firstOrNull?.reference;
      if (cur == null) return;
      _mutate((d) => d.setReferenceById(
          lineId,
          LineRef(
            startMs: cur.startMs,
            endMs: cur.endMs,
            videoPath: cur.videoPath,
            imagePath: cur.imagePath,
            cuts: cur.cuts,
            words: words,
            shotMeta: cur.shotMeta,
          )));
    } catch (e) {
      AppLog.warn('参考视频 ASR 失败（只影响展示，$lineId）：$e');
    }
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
    // 试听开始前停掉分镜卡/主预览——同时只有一个东西在响
    _stopInline();
    await _playback?.pause();
    setState(() => _playingLineId = line.id);
    await _voicePreview.play(vo.audioPath);
    // 简单起见按时长收尾：播完把按钮复位（期间切行/重播由上面的分支处理）
    Future.delayed(Duration(milliseconds: vo.durationMs + 200), () {
      if (mounted && _playingLineId == line.id) {
        setState(() => _playingLineId = null);
      }
    });
  }

  /// 撤销/重做栈：ScriptDoc 不可变，存引用零拷贝。上限防内存无限涨
  final List<ScriptDoc> _undoStack = [];
  final List<ScriptDoc> _redoStack = [];
  static const _undoLimit = 100;

  /// 改动随手落库（800ms 防抖）——写作软件没有「保存」这回事。
  /// 每次改动前把旧文档压进撤销栈（新改动作废重做栈）
  void _mutate(ScriptDoc Function(ScriptDoc) f) {
    _undoStack.add(_doc);
    if (_undoStack.length > _undoLimit) _undoStack.removeAt(0);
    _redoStack.clear();
    setState(() {
      _doc = f(_doc);
      _saving = true;
    });
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 800), _flushNow);
    _schedulePreviewRebuild();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_doc);
    setState(() => _doc = _undoStack.removeLast());
    _flushNow();
    _schedulePreviewRebuild();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_doc);
    setState(() => _doc = _redoStack.removeLast());
    _flushNow();
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
            bgmSegments: _doc.bgmSegments,
            refVideoPath: path);
        _selected = 0;
        _extract = null;
        _guideDismissed = true;
      });
      _flushNow();
      unawaited(_offerDraftAfterExtract());
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

  /// 提取完成后追问一次「生成草片」：打标 → 配音 → 配镜 → 直接开播。
  /// 一次确认把费用说清，之后人只做否决和替换——这是产品的北极星
  Future<void> _offerDraftAfterExtract() async {
    if (!mounted) return;
    final tagger = ref.read(lineTaggerProvider);
    final voiceFactory = ref.read(lineVoiceFactoryProvider);
    final voiced = [
      for (final l in _doc.lines)
        if (l.type == ScriptLineType.voiced) l.id,
    ];
    if (voiced.isEmpty) return;
    final canTag = tagger != null && _task.unitTagGroups.isNotEmpty;
    final canVoice = voiceFactory != null;
    final defaultVoice = VoiceCatalog.all.first.ref.name;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('直接生成一版草片？'),
        content: Text([
          '脚本已经就位（${voiced.length} 句）。接下来可以自动：',
          if (canTag) '· 给每句打上标签（${voiced.length} 次 AI 调用）',
          if (canVoice)
            '· 用「$defaultVoice」配上声音（${voiced.length} 次语音合成，之后每句可换）',
          '· 按标签或台词给每句配一个镜头',
          '几分钟后草片会直接播出来，不满意的随手替换。',
        ].join('\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('我自己一句句来')),
          FilledButton(
              key: const ValueKey('draft-after-extract'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('生成草片')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    // 阶段〇：打标（有词表才打；失败不挡路，退回按台词搜镜头）
    if (canTag) {
      for (var i = 0; i < voiced.length; i++) {
        if (!mounted) return;
        final line = _doc.lines.where((l) => l.id == voiced[i]).firstOrNull;
        if (line == null) continue;
        setState(() =>
            _draftProgress = ('打标', line.text.trim(), i, voiced.length));
        try {
          final tags = await tagger.tag(
            text: line.text,
            groups: _task.unitTagGroups,
            constraint: _task.unitTagPrompt,
          );
          if (!mounted) return;
          if (tags.isNotEmpty) _mutate((d) => d.setTagsById(line.id, tags));
        } catch (e) {
          AppLog.warn('草片打标失败（第 ${i + 1} 句）：$e');
        }
      }
    }
    final needVoice = canVoice
        ? [
            for (final l in _doc.lines)
              if (l.type == ScriptLineType.voiced &&
                  l.voiceState != LineVoiceState.fresh)
                l.id,
          ]
        : <String>[];
    final needShots = [
      for (final l in _doc.lines)
        if (l.shots.isEmpty && l.type == ScriptLineType.voiced) l.id,
    ];
    await _runDraftPipeline(
        needVoice: needVoice,
        needShots: needShots,
        defaultVoice: VoiceCatalog.all.first.ref.id);
  }

  // ---- 草片流水线（北极星：人是来看片子诞生的，不是来操作块的）----

  /// 一键生成草片：给还没配音的句子配上音、还没镜头的句子自动配镜，
  /// 全部完成后草片直接开播。花钱的事先说清再动手
  Future<void> _generateDraft() async {
    if (_draftProgress != null) return;
    final voiceFactory = ref.read(lineVoiceFactoryProvider);
    final needVoice = [
      for (final l in _doc.lines)
        if (l.type == ScriptLineType.voiced &&
            l.voiceState != LineVoiceState.fresh)
          l.id,
    ];
    final needShots = [
      for (final l in _doc.lines)
        if (l.shots.isEmpty && (l.type == ScriptLineType.voiced))
          l.id,
    ];
    if (needVoice.isEmpty && needShots.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('每一句都已经就绪，直接按播放看草片。')));
      return;
    }
    if (needVoice.isNotEmpty && voiceFactory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务（语音合成），生成不了草片。')));
      return;
    }
    // 默认音色：全片最近用过的，其次目录第一个——批量时绝不弹 27 次选择器
    final defaultVoice = _doc.lines
            .lastWhere((l) => l.voiceId != null,
                orElse: () => _doc.lines.first)
            .voiceId ??
        VoiceCatalog.all.first.ref.id;
    final defaultVoiceName =
        VoiceCatalog.byId(defaultVoice)?.ref.name ?? defaultVoice;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('生成草片？'),
        content: Text([
          if (needVoice.isNotEmpty)
            '· 给 ${needVoice.length} 句配上「$defaultVoiceName」的声音'
                '（${needVoice.length} 次语音合成，每句之后可单独换）',
          if (needShots.isNotEmpty)
            '· 给 ${needShots.length} 句自动配一个镜头（按标签或台词从素材库找）',
          '完成后草片会直接播出来，不满意的镜头随手替换。',
        ].join('\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('先不用')),
          FilledButton(
              key: const ValueKey('draft-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('生成草片')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _runDraftPipeline(
        needVoice: needVoice, needShots: needShots, defaultVoice: defaultVoice);
  }

  /// 补上逐字时间：早期生成的配音只有整段音频、没有每个字的时间戳，
  /// 字幕就只能按字数把时间摊开，也没法手工分屏与打轴。这里把全片
  /// 缺时间的行**重配一次音**（同音色同台词，声音听不出差别）。
  ///
  /// 会花钱、会让行时长有毫秒级变化（镜头分配跟着重算），所以先说清
  /// 再动手；跑的时候顶栏有进度，失败的行会点名
  Future<void> _fixMissingWordTimings() async {
    if (_draftProgress != null) return;
    final need = [
      for (final l in _doc.lines)
        if (l.type == ScriptLineType.voiced &&
            l.voiceover != null &&
            l.voiceover!.words.isEmpty)
          l.id,
    ];
    if (need.isEmpty) {
      _toast('每一句都已经有逐字时间了。');
      return;
    }
    if (ref.read(lineVoiceFactoryProvider) == null) {
      _toast('尚未配置 AI 服务（语音合成），补不了逐字时间。');
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('补上逐字时间？'),
        content: Text([
          '有 ${need.length} 句配音是早期生成的，没带每个字的时间戳，',
          '所以字幕只能按字数摊时间，也改不了切点。',
          '',
          '· 这 ${need.length} 句会用**原来的音色和台词**重配一次'
              '（${need.length} 次语音合成），声音听不出差别',
          '· 行的时长可能有毫秒级变化，镜头分配会跟着重算',
          '· 补完就能手工分屏、按播放位置打轴',
        ].join('\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('先不用')),
          FilledButton(
              key: const ValueKey('fix-timing-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('补上')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final failed = <String>[];
    for (var i = 0; i < need.length; i++) {
      if (!mounted) return;
      final line = _doc.lines.where((l) => l.id == need[i]).firstOrNull;
      if (line == null) continue; // 期间被删了
      setState(() =>
          _draftProgress = ('补逐字时间', line.text.trim(), i, need.length));
      final voiceId = line.voiceId ??
          _doc.lines
              .lastWhere((l) => l.voiceId != null, orElse: () => line)
              .voiceId;
      if (voiceId == null) {
        failed.add(line.text.trim());
        continue;
      }
      final ok = await _generateVoiceCore(line.id, voiceId);
      // 重配了还是没有逐字时间（老服务端/长句）——也算没补上，别装成功
      final after = _doc.lines.where((l) => l.id == line.id).firstOrNull;
      if (!ok || (after?.voiceover?.words.isEmpty ?? true)) {
        failed.add(line.text.trim());
      }
    }
    if (!mounted) return;
    setState(() => _draftProgress = null);
    _flushNow();
    _schedulePreviewRebuild();
    if (failed.isEmpty) {
      _toast('${need.length} 句都补上了逐字时间，现在可以手工分屏与打轴。');
    } else {
      // 不静默：补不上的点名，剩下的照常可用
      _toast('${need.length - failed.length} 句补好了；'
          '${failed.length} 句没补上（${failed.first}…），可以单独重新生成配音。');
    }
  }

  Future<void> _runDraftPipeline({
    required List<String> needVoice,
    required List<String> needShots,
    required String defaultVoice,
  }) async {
    var voiceFailed = 0;
    var shotFailed = 0;
    // 一、配音
    for (var i = 0; i < needVoice.length; i++) {
      if (!mounted) return;
      final line = _doc.lines.where((l) => l.id == needVoice[i]).firstOrNull;
      if (line == null) continue; // 生成期间被删了
      setState(() => _draftProgress =
          ('配音', line.text.trim(), i, needVoice.length));
      if (line.voiceId == null) {
        _mutate((d) => d.setVoiceId(
            _doc.lines.indexWhere((l) => l.id == line.id), defaultVoice));
      }
      final ok = await _generateVoiceCore(
          line.id, _doc.lines.firstWhere((l) => l.id == line.id).voiceId!);
      if (!ok) voiceFailed++;
    }
    // 二、配镜
    final tagIds = needShots.isEmpty ? const <String, int>{} : await _loadTagIds();
    for (var i = 0; i < needShots.length; i++) {
      if (!mounted) return;
      final line = _doc.lines.where((l) => l.id == needShots[i]).firstOrNull;
      if (line == null) continue;
      setState(() =>
          _draftProgress = ('找镜头', line.text.trim(), i, needShots.length));
      final ok = await _autoPickShot(line.id, tagIds);
      if (!ok) shotFailed++;
    }
    if (!mounted) return;
    // 三、完成一拍 + 开播——魔法时刻要有个 crescendo：进度收束成
    // 「草片好了」的对勾一拍（1.1s），然后播放器入场直接开播
    setState(() {
      _draftProgress = null;
      _draftCelebrating = true;
    });
    _flushNow();
    _pinAllShots();
    _schedulePreviewRebuild();
    unawaited(
        Future<void>.delayed(const Duration(milliseconds: 1100), () async {
      if (!mounted) return;
      setState(() => _draftCelebrating = false);
      await _playback?.seekMs(0);
      await _playback?.play();
    }));
    final problems = [
      if (voiceFailed > 0) '$voiceFailed 句配音没成',
      if (shotFailed > 0) '$shotFailed 句没找到合适的镜头',
    ];
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(problems.isEmpty
            ? '草片好了，正在播——不满意的镜头随手换。'
            : '草片好了（${problems.join('、')}，对应句子可以手动补）。')));
  }

  /// 任务标签组的 标签名 → id 映射（自动配镜按标签检索用）。拉不到不挡路
  Future<Map<String, int>> _loadTagIds() async {
    try {
      final services = ref.read(shotSearchServicesProvider);
      final groups = await services.tags.listGroups();
      final wanted = {for (final g in _task.unitTagGroups) g.id};
      final ids = <String, int>{};
      for (final g in groups) {
        if (!wanted.contains(g.id)) continue;
        for (final t in await services.tags.listTags(g.id)) {
          ids.putIfAbsent(t.name, () => t.id);
        }
      }
      return ids;
    } catch (e) {
      AppLog.warn('自动配镜拉标签词表失败（退回按台词搜）：$e');
      return const {};
    }
  }

  /// 给一句自动配一个镜头：按行标签检索（其次按台词的画面描述搜），
  /// 取第一个没被别的句子占用的候选，探好时长落地并按行时长分配
  Future<bool> _autoPickShot(String lineId, Map<String, int> tagIds) async {
    try {
      final services = ref.read(shotSearchServicesProvider);
      final line = _doc.lines.firstWhere((l) => l.id == lineId);
      final ids = [
        for (final t in line.tags) ?tagIds[t],
      ];
      final page = ids.isNotEmpty
          ? await services.content.searchByTags(
              tagIds: ids,
              projectIds: [if (_task.project != null) _task.project!.id],
              pageSize: 10)
          : await services.content.searchByDescription(
              keyword: line.text.trim(),
              projectIds: [if (_task.project != null) _task.project!.id],
              pageSize: 10);
      final used = <int>{
        for (final l in _doc.lines)
          for (final s in l.shots)
            if (s.localSource == null) s.materialId,
      };
      final pick = page.items
          .where((m) => !used.contains(m.id) && m.previewUrl != null)
          .firstOrNull;
      if (pick == null) return false;
      final spec = await services.probe
          .probe(materialId: pick.id, previewUrl: pick.previewUrl);
      final shot = LineShot(
        materialId: pick.id,
        name: pick.name,
        voiceover: pick.voiceover,
        sceneDescription: pick.sceneDescription,
        thumbnailUrl: pick.thumbnailUrl,
        fileKey: pick.fileKey,
        durationMs: spec?.durationMs,
      );
      final current = _doc.lines.firstWhere((l) => l.id == lineId);
      final withShot = current.withShots([...current.shots, shot]);
      final root = ShotAllocation.rootMsOf(withShot);
      // 素材短于行时长就放慢充满——自动配的镜头不许留「没充满」的尾巴
      _mutate((d) => d.setShotsById(
          lineId,
          root == null
              ? withShot.shots
              : ShotAllocation.fillBySlowdown(
                  ShotAllocation.distribute(withShot.shots, root), root)));
      return true;
    } catch (e) {
      AppLog.warn('自动配镜失败（line=$lineId）：$e');
      return false;
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
    // 全页快捷键：空格播放/暂停、←→ 秒跳、⌘Z 撤销、⇧⌘Z 重做。
    // 文本框有焦点时这些键先被输入框消费，不会打架
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () {
          if (!_planResult.isEmpty && _videoWidget != null) {
            unawaited(_togglePreviewPlay());
          }
        },
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            unawaited(_seekPreview((_positionMs.value - 1000).clamp(
                0, _planResult.plan.totalMs))),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            unawaited(_seekPreview((_positionMs.value + 1000).clamp(
                0, _planResult.plan.totalMs))),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyZ,
            meta: true, shift: true): _redo,
      },
      child: FocusScope(
        autofocus: true,
        child: Scaffold(
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
                    previewLineIndex: _previewLineIndex,
                    inlineKey: _inlineKey,
                    inlineVideo: _inlineVideo,
                    inlinePosition: _inlinePositionMs,
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
                      onSlowFill: _slowFill,
                      onEditTags: _editTags,
                      shotFramesOf: (shot) {
                        _ensureShotFrames(shot);
                        final frames = _shotFrames[shot.materialId];
                        if (frames == null) return null;
                        return (
                          frames: frames,
                          aspect:
                              _shotFrameAspect[shot.materialId] ?? 9 / 16,
                        );
                      },
                      onPlayShot: _playShotInline,
                      onTrimDone: _scheduleReplayShot,
                      subtitleStyleOf: _styleOf,
                      onScreenText: (index, screenIndex, text) {
                        final line = _doc.lines[index];
                        _mutate((d) => d.setScreenTextById(
                            line.id, screenIndex, text,
                            maxChars: _styleOf(line).maxCharsPerScreen));
                      },
                      onScreenMerge: (index, screenIndex) {
                        final line = _doc.lines[index];
                        _mutate((d) => d.mergeScreenById(line.id, screenIndex,
                            maxChars: _styleOf(line).maxCharsPerScreen));
                      },
                      onScreenCut: (index, atMs) {
                        final line = _doc.lines[index];
                        _mutate((d) => d.cutScreenById(line.id, atMs,
                            maxChars: _styleOf(line).maxCharsPerScreen));
                      },
                      onFixTimings: _fixMissingWordTimings,
                      onScreenReset: (index) {
                        final line = _doc.lines[index];
                        _mutate((d) => d.resetScreensById(line.id));
                      },
                      onSubtitleCutHere: _cutSubtitleHere,
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
                      bgmOf: (lineIndex) {
                        final rail = bgmRail(_doc.bgmSegments, _doc.lines.length);
                        for (var i = 0; i < rail.length; i++) {
                          if (lineIndex >= rail[i].startLine &&
                              lineIndex <= rail[i].endLine) {
                            return (
                              index: i,
                              seg: rail[i],
                              isHead: lineIndex == rail[i].startLine
                            );
                          }
                        }
                        return (
                          index: 0,
                          seg: BgmRailSegment(
                              startLine: 0,
                              endLine: 0,
                              material: null,
                              volume: BgmSegment.defaultVolume),
                          isHead: true
                        );
                      },
                      bgmStatus: (id) => _bgmCache?.statusOf(id),
                      onRetryBgm: (id) {
                        _bgmCache?.retry(id);
                        _toast('正在重新下载这首配乐…');
                      },
                      onBgmSplit: _bgmSplitAt,
                      onBgmEdit: _bgmEditSegment,
                      onBgmMoveBoundary: (segIndex, delta) {
                        final rail =
                            bgmRail(_doc.bgmSegments, _doc.lines.length);
                        if (segIndex <= 0 || segIndex >= rail.length) return;
                        final next = moveRailBoundary(rail, segIndex,
                            rail[segIndex].startLine + delta);
                        _mutate((d) => d.withBgmSegments(railToSegments(next)));
                      },
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
        ),
      ),
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
            // 还没配乐时：一键给整片配一首（整片就是一段）。
            // 分段在右栏色带上做——「从这一句开始换一首」
            onPressed: () => _bgmEditSegment(0),
            iconSize: 16,
            icon: Icon(Icons.music_note,
                color: _doc.bgmSegments.isEmpty
                    ? AppColors.textSecondary
                    : AppColors.accentBlueLight),
            tooltip: _doc.bgmSegments.isEmpty
                ? '给整片配一首（分段在右栏色带上切）'
                : '配乐：${_doc.bgmSegments.length} 段',
          ),
          // 顶栏只留可重复、非破坏的动作：配乐 · 生成草片 · 导出成片。
          // 「字幕样式」由预览下方的工具条 +「应用到整片」接管；
          // 「从视频提取脚本」是空脚本时的一次性起步动作（会覆盖整份
          // 脚本、把配音镜头字幕全作废），只留在起步引导里
          const SizedBox(width: AppSpacing.xs),
          _draftButton(),
          const SizedBox(width: AppSpacing.sm),
          _exportButton(),
          const SizedBox(width: AppSpacing.xs),
        ]),
      );

  /// 还有句子没配好吗——顶栏主次按它定
  bool get _draftHasWork => _doc.lines.any((l) =>
      l.type == ScriptLineType.voiced &&
      (l.voiceState != LineVoiceState.fresh || l.shots.isEmpty));

  /// 「生成草片」的主次是动态的：还有句子没配好时它才是这一屏的主动作
  /// （实心蓝），全就绪后让位给「导出成片」——一屏只有一个主角，
  /// 所以两个按钮的实心/描边永远互补（见 [_exportButton]）
  Widget _draftButton() {
    final label = Text(_draftProgress != null ? '生成中…' : '生成草片');
    const icon = Icon(Icons.auto_awesome, size: 14);
    final onPressed = _draftProgress != null ? null : _generateDraft;
    if (_draftHasWork) {
      return FilledButton.icon(
        key: const ValueKey('director-draft'),
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accentBlue,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: 6),
          textStyle: const TextStyle(
              fontSize: AppFontSize.body, fontWeight: FontWeight.w600),
        ),
        icon: icon,
        label: label,
      );
    }
    return OutlinedButton.icon(
      key: const ValueKey('director-draft'),
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.border),
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
        textStyle: const TextStyle(fontSize: AppFontSize.body),
      ),
      icon: icon,
      label: label,
    );
  }

  /// 「导出成片」与「生成草片」互补：草片还有活时退居描边，
  /// 全就绪后成为唯一的实心主角
  Widget _exportButton() {
    final label = Text(_exporting ? '导出中…' : '导出成片');
    const icon = Icon(Icons.ios_share, size: 14);
    final onPressed = _exporting ? null : _exportScript;
    if (_draftHasWork) {
      return OutlinedButton.icon(
        key: const ValueKey('director-export'),
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.border),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: 6),
          textStyle: const TextStyle(fontSize: AppFontSize.body),
        ),
        icon: icon,
        label: label,
      );
    }
    return FilledButton.icon(
      key: const ValueKey('director-export'),
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accentBlue,
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
        textStyle: const TextStyle(
            fontSize: AppFontSize.body, fontWeight: FontWeight.w600),
      ),
      icon: icon,
      label: label,
    );
  }

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
    // 草片刚做完：对勾一拍（elasticOut 弹入），紧接着开播
    if (_draftCelebrating) {
      return Container(
        color: AppColors.stageWell,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 600),
              curve: Curves.elasticOut,
              builder: (_, v, child) => Transform.scale(scale: v, child: child),
              child: Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: AppColors.green),
                child: const Icon(Icons.check_rounded,
                    size: 34, color: Colors.white),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const Text('草片好了',
                style: TextStyle(
                    fontSize: AppFontSize.title,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: AppSpacing.xs),
            const Text('这就播给你看',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
          ]),
        ),
      );
    }
    // 草片流水线进行中：舞台交给进度——用户看着自己的片子一句句长出来，
    // 而不是对着死黑块等
    if (_draftProgress case (final stage, final text, final done, final total)) {
      return Container(
        color: AppColors.stageWell,
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  value: total == 0 ? null : (done + 1) / total,
                  strokeWidth: 3,
                  color: AppColors.accentBlue,
                  backgroundColor: AppColors.surfaceCard,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('正在给第 ${done + 1} / $total 句$stage',
                  style: const TextStyle(
                      fontSize: AppFontSize.emphasis,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(height: AppSpacing.sm),
              Text('「${text.length > 24 ? '${text.substring(0, 24)}…' : text}」',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary,
                      height: 1.5)),
              const SizedBox(height: AppSpacing.md),
              const Text('完成后草片会直接播出来',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary)),
            ]),
          ),
        ),
      );
    }
    final playable = !_planResult.isEmpty && _videoWidget != null;
    return Container(
      color: AppColors.stageWell,
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
                      ? Stack(fit: StackFit.expand, children: [
                          _videoWidget!,
                          // 实时字幕层：播放到哪句显示哪句，样式即改即见
                          // （所见即所得——不用导出才知道字幕长什么样）
                          ValueListenableBuilder<int>(
                            valueListenable: _positionMs,
                            builder: (_, _, _) => _previewSubtitle(),
                          ),
                        ])
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
          // 传输条：可播时活的（进度条可拖动定位），不可播时禁用态骨架
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
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
            Flexible(
              child: ValueListenableBuilder<int>(
                valueListenable: _positionMs,
                builder: (_, ms, _) {
                  final total = _planResult.plan.totalMs;
                  final shown = (_dragMs ?? (playable ? ms : 0))
                      .clamp(0, total > 0 ? total : 1);
                  return SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 5),
                      overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 11),
                      activeTrackColor: AppColors.accentBlue,
                      inactiveTrackColor: AppColors.surfaceCard,
                      thumbColor: AppColors.accentBlueLight,
                    ),
                    child: Slider(
                      key: const ValueKey('director-preview-seek'),
                      value: shown.toDouble(),
                      max: (total > 0 ? total : 1).toDouble(),
                      onChanged: playable
                          ? (v) => setState(() => _dragMs = v.round())
                          : null,
                      onChangeEnd: playable
                          ? (v) {
                              setState(() => _dragMs = null);
                              unawaited(_seekPreview(v.round()));
                            }
                          : null,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            ValueListenableBuilder<int>(
              valueListenable: _positionMs,
              builder: (_, ms, _) => Text(
                  '${_mmss(_dragMs ?? (playable ? ms : 0))} / ${_mmss(_planResult.plan.totalMs)}',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: playable
                          ? AppColors.textSecondary
                          : AppColors.textTertiary.withValues(alpha: 0.5),
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ])),
          if (playable) _subtitleToolbar(),
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

  /// 字幕工具条（常驻在预览正下方，用户定的 A 方案）：调什么、看什么
  /// 在同一视线里——不再用弹窗盖住唯一能看出效果的地方。
  /// 跟着**当前这一句**走（播到哪句就是哪句，否则是选中的那句）；
  /// 样式粒度 = 句，右端「整片」把这套提升为全局基调
  Widget _subtitleToolbar() {
    final index = _subtitleTargetIndex;
    if (_doc.lines.isEmpty) return const SizedBox.shrink();
    final line = _doc.lines[index];
    if (line.type != ScriptLineType.voiced) return const SizedBox.shrink();
    final style = _styleOf(line);

    void draft(SubtitleStyle next) {
      setState(() {
        _styleDraft = next;
        _styleDraftLineId = line.id;
      });
    }

    void commit(SubtitleStyle next) {
      setState(() {
        _styleDraft = null;
        _styleDraftLineId = null;
      });
      _mutate((d) => d.setSubtitleOverrideById(line.id, next));
    }

    Widget slider({
      required String label,
      required Key key,
      required double value,
      required double min,
      required double max,
      required String trailing,
      required SubtitleStyle Function(double v) build,
    }) =>
        Row(children: [
          SizedBox(
              width: 28,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textSecondary))),
          Expanded(
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 2,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: RoundSliderOverlayShape(overlayRadius: 10),
              ),
              child: Slider(
                key: key,
                value: value.clamp(min, max),
                min: min,
                max: max,
                activeColor: AppColors.accentBlue,
                onChanged: (v) => draft(build(v)),
                onChangeEnd: (v) => commit(build(v)),
              ),
            ),
          ),
          SizedBox(
              width: 42,
              child: Text(trailing,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary,
                      fontFeatures: [FontFeature.tabularFigures()]))),
        ]);

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Text('第 ${index + 1} 句的字幕',
              style: const TextStyle(
                  fontSize: AppFontSize.micro,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary)),
          const Spacer(),
          if (line.subtitleOverride != null) ...[
            InkWell(
              key: const ValueKey('subtitle-bar-reset'),
              onTap: () =>
                  _mutate((d) => d.setSubtitleOverrideById(line.id, null)),
              child: const Text('跟随整片',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary)),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          InkWell(
            key: const ValueKey('subtitle-bar-apply-all'),
            onTap: () => _mutate((d) =>
                d.withSubtitle(style).setSubtitleOverrideById(line.id, null)),
            child: const Text('应用到整片',
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    color: AppColors.accentBlueLight)),
          ),
        ]),
        slider(
          label: '位置',
          key: const ValueKey('subtitle-bar-bottom'),
          value: style.bottomRatio,
          min: 0.03,
          max: 0.6,
          trailing: '${(style.bottomRatio * 100).round()}%',
          build: (v) => style.copyWith(bottomRatio: v),
        ),
        slider(
          label: '字号',
          key: const ValueKey('subtitle-bar-font'),
          value: style.fontRatio,
          min: 0.018,
          max: 0.065,
          trailing: '${(style.fontRatio * 1000).round()}‰',
          build: (v) => style.copyWith(fontRatio: v),
        ),
        Row(children: [
          for (final (hex, name) in subtitleColors)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Tooltip(
                message: name,
                child: InkWell(
                  key: ValueKey('subtitle-bar-color-$hex'),
                  onTap: () => commit(style.copyWith(
                      colorHex: hex == 'FFFFFF' ? null : hex)),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(int.parse('FF$hex', radix: 16)),
                      border: Border.all(
                          color: (style.colorHex ?? 'FFFFFF') == hex
                              ? AppColors.accentBlue
                              : AppColors.border,
                          width: (style.colorHex ?? 'FFFFFF') == hex ? 2 : 1),
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(width: AppSpacing.xs),
          for (final (preset, label) in const [
            (SubtitlePreset.whiteOutline, '无底'),
            (SubtitlePreset.blurBox, '毛玻璃'),
            (SubtitlePreset.whiteBox, '黑条'),
          ])
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: InkWell(
                key: ValueKey('subtitle-bar-mask-${preset.name}'),
                onTap: () => commit(style.copyWith(preset: preset)),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: style.preset == preset
                        ? AppColors.accentBlue.withValues(alpha: 0.16)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: style.preset == preset
                            ? AppColors.accentBlue
                            : AppColors.border),
                  ),
                  child: Text(label,
                      style: TextStyle(
                          fontSize: AppFontSize.micro,
                          color: style.preset == preset
                              ? AppColors.accentBlueLight
                              : AppColors.textSecondary)),
                ),
              ),
            ),
        ]),
      ]),
    );
  }

  /// 当前播放行的字幕：按镜头边界与词级时间戳切段（与导出同一套规则）
  /// ——「家人们」只在第一镜出现，后半句归后面的镜头。画面行没台词不出。
  /// 字幕本身可操作：点一下改样式，上下拖直接调位置
  Widget _previewSubtitle() {
    final index = _previewLineIndex;
    if (index == null || index < 0 || index >= _doc.lines.length) {
      return const SizedBox.shrink();
    }
    final line = _doc.lines[index];
    if (line.type != ScriptLineType.voiced) return const SizedBox.shrink();
    final lineStart = _planResult.lineStarts[index] ?? 0;
    final relMs = _positionMs.value - lineStart;
    // 字幕屏：切点跟语言走，与镜头无关；每屏字数按**生效样式**的字号推，
    // 与镜头卡、卡上播放、成片导出取的是同一份派生
    final seg = line
        .subtitleScreensAt(maxChars: _styleOf(line).maxCharsPerScreen)
        .where((s) => relMs >= s.startMs && relMs < s.endMs)
        .firstOrNull;
    final text = seg?.text ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    final style = _styleOf(line);
    return PreviewSubtitle(
      text: text,
      style: style,
      // 点字幕 = 选中这一句（样式调整在预览正下方的工具条里，
      // 不再用弹窗盖住预览）
      onTap: () => _focusLine(index),
      onDragRatio: (ratio) =>
          setState(() => _subtitleDragRatio = ratio),
      onDragEnd: (ratio) {
        _subtitleDragRatio = null;
        // 样式粒度 = 句：拖字幕改的就是这一句
        _mutate((d) => d.setSubtitleOverrideById(
            line.id, style.copyWith(bottomRatio: ratio)));
      },
      dragRatio: _subtitleDragRatio,
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
class _SublineCutDialog extends StatefulWidget {
  final String text;
  final int suggest;

  const _SublineCutDialog({required this.text, required this.suggest});

  @override
  State<_SublineCutDialog> createState() => _SublineCutDialogState();
}

class _SublineCutDialogState extends State<_SublineCutDialog> {
  late int _cut = widget.suggest.clamp(1, widget.text.length - 1);

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('这段台词从哪里分开？',
            style: TextStyle(fontSize: AppFontSize.title)),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('点一个字，从它前面切开——前半段归上面的镜头组，'
                '后半段归下面的',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.md),
            Wrap(spacing: 0, runSpacing: 4, children: [
              for (var i = 0; i < widget.text.length; i++)
                InkWell(
                  key: ValueKey('subline-char-$i'),
                  onTap: i == 0 ? null : () => setState(() => _cut = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 1, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border(
                          left: BorderSide(
                              color: i == _cut
                                  ? AppColors.accentBlue
                                  : Colors.transparent,
                              width: 2)),
                      color: i >= _cut
                          ? AppColors.accentBlue.withValues(alpha: 0.10)
                          : Colors.transparent,
                    ),
                    child: Text(widget.text[i],
                        style: const TextStyle(
                            fontSize: AppFontSize.emphasis,
                            height: 1.5,
                            color: AppColors.textPrimary)),
                  ),
                ),
            ]),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
            key: const ValueKey('subline-cut-ok'),
            onPressed: () => Navigator.of(context).pop(_cut),
            child: const Text('就这样分'),
          ),
        ],
      );
}

