import 'dart:async';

import 'package:flutter/widgets.dart';

import '../log/app_log.dart';
import 'edl.dart';
import 'follower_track.dart';
import 'media_kit_playback.dart';
import 'playback_controller.dart';
import 'track_plan.dart';

/// 三条独立轨同时播：画面 + 口播 + 配乐。
///
/// **为什么不再预合成**：此前预览要先用 ffmpeg 把几十段拼成一整条新片子再喂
/// 给播放器，一轮几分钟、几百兆磁盘，而其中绝大多数段是把原片原封不动切了
/// 一遍。用户原话：「它就不能像剪映一样各是各的吗？播放的时候一起播放。」
///
/// 分工：
/// - **画面轨**是主时钟，且**静音**——它播的可能是候选素材，那条素材自带的
///   声音由口播轨负责取（整体替换要它、镜头替换要丢掉它），画面轨出声只会
///   变成两份声音重叠；
/// - **口播轨**跟着主时钟走，偏差超过 [syncToleranceMs] 才纠一次；
/// - **配乐轨**按范围启停：进入某一段就 seek 到曲子对应的位置播，出了范围
///   就停（「太长就播到段尾停」），曲子比段短就绕回开头（「不够长就循环」）。
///
/// 画面轨复用 [MediaKitPlaybackController]——那里面沉淀了一串 mpv 的坑
/// （eof 后 play 会从头播、清 end 会自己恢复播放、销毁竞态会让进程 abort），
/// 不该为了多轨再踩一遍。
class MultitrackPlayback implements PlaybackController {
  /// 画面轨兼主时钟
  final MasterTrack video;
  final FollowerTrack voice;
  final FollowerTrack bgm;

  /// 素材自带的原声（音效那一路）。
  ///
  /// **必须是独立的一条轨，不能挂在画面轨上**：画面轨拼的是几十条来路不同
  /// 的素材，有的带音轨有的不带，让它出声就意味着播到接缝处要重建音频链路，
  /// 主时钟会当场卡住好几秒（真机：卡在 9955ms 不动，口播被反复拽回同一处，
  /// 听感是一个词反复念十几遍）。分出来之后画面轨永远不解码音频，接缝不存在了。
  /// null = 这个装配不播原声（测试/精简环境）
  final FollowerTrack? source;

  /// 多久校一次跟随轨。太密会被采样抖动骗得反复 seek，太疏则接缝期变长
  final Duration syncInterval;

  TrackPlan _plan = TrackPlan.empty;
  StreamSubscription<int>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _syncTimer;
  BgmCue _bgmCue = BgmCue.silent;

  /// 画面轨当前加载的那条 EDL。没变就不重新 open——open 会闪一下黑
  String? _videoEdl;
  bool _disposed = false;

  /// 纠偏 seek 实测要多久。见 [_correctDrift]：没有它，每纠一次就制造下一次
  int _seekCostMs = 0;

  /// 上一次纠偏还没落地。定时器不等前一次跑完就再触发的话，
  /// 两次 seek 会叠在一起，谁也纠不准
  bool _correcting = false;

  MultitrackPlayback({
    required this.video,
    required this.voice,
    required this.bgm,
    this.source,
    this.syncInterval = const Duration(milliseconds: 500),
  }) {
    _positionSub = video.positionMsStream.listen(_onMasterPosition);
    _playingSub = video.playingStream.listen(_onMasterPlaying);
  }

  TrackPlan get plan => _plan;

  /// 换一套轨。
  ///
  /// 用户点一下 ★、取消一个勾选，走的就是这里。三条**必须**守住的规矩：
  /// - **画面轨没变就一帧都不动**。改配乐、改音量、改别的单元的候选时，
  ///   画面轨往往一模一样——无条件重新 open 会让画面白闪一下黑；
  /// - **保持播放状态**。正在播的时候点一下 ★ 就停住，是不能接受的；
  /// - **按逻辑位置恢复**。记的是「我停在原片的哪一刻」，不是「第几毫秒」
  ///   ——取消整体替换之后成片总长会变，同一个毫秒对应的内容完全不是同一处。
  @override
  Future<void> clearSource() async {
    _videoEdl = null;
    await video.clearSource();
  }

  Future<void> setPlan(TrackPlan plan) async {
    final wasPlaying = video.isPlaying;
    // 换之前先记下逻辑位置（用旧的那套轨换算）
    final sourceMs = _plan.video.isEmpty
        ? null
        : _plan.toSourceMs(video.positionMs);

    _plan = plan;
    final videoEdl = Edl.of(plan.video);
    // 画面轨空了（空白任务一条素材都没挑）必须**明确清掉**。
    //
    // 原来只在 videoEdl != null 时才换源，于是空轨等于「什么都不做」——
    // 播放器里还挂着上一次打开的东西，用户看到的是**别的任务的画面**。
    // 真机上撞到过：新建的空白任务里播着上一条滴露成片的一帧。
    if (videoEdl == null && _videoEdl != null) {
      _videoEdl = null;
      AppLog.info('画面轨清空（没有可播的段落）');
      await video.clearSource();
    }
    final videoChanged = videoEdl != null && videoEdl != _videoEdl;
    if (videoChanged) {
      _videoEdl = videoEdl;
      // 换了什么必须留痕：这套「谁在什么时候播哪个文件的哪一段」是产品的核心，
      // 出问题时没有它就只能靠猜
      AppLog.info('画面轨换源，共 ${plan.video.length} 段：$videoEdl');
      await video.open(videoEdl);
      // 画面轨不解码音频：这条轨拼的是几十条来路不同的素材，有的带音轨
      // 有的不带，播到接缝处播放器要重建音频链路，主时钟会卡住好几秒
      // （真机 16 处这样的接缝，第一处就在第 2 句里）
      await video.disableAudio();
    }
    // 素材原声挂在独立的一条轨上，跟着画面段走（见 [_applySource]）
    await _applySource(video.positionMs, force: true);
    final voiceEdl = Edl.of(plan.voice);
    final voiceChanged = await voice.load(voiceEdl);
    // 口播轨总音量：整轨一个数（EDL 没法逐段设）。
    // 换不换源都要设——人拉的可能就是这根滑杆
    await voice.setVolume(plan.voiceVolume);
    if (voiceChanged) {
      AppLog.info('口播轨换源，共 ${plan.voice.length} 段：$voiceEdl');
    }

    if (videoChanged || voiceChanged) {
      // 换源之后位置回到 0，按逻辑位置拉回用户原来看的地方
      final at = sourceMs == null
          ? 0
          : plan.toComposedMs(sourceMs).clamp(0, plan.totalMs);
      if (at > 0) {
        await video.seekMs(at);
        await voice.seekMs(at);
      }
      await _applyBgm(at, force: true);
      // 换源必然要重开文件、重新定位，这一下的停顿是**已知代价**，
      // 不是异常。基线不重置的话，代理刚生成好那一刻的换源会被探针报成
      // 「0.74×」「1.40×」，把真信号淹掉
      _resetPace();
      // 换源前在播的话，换完接着播——点一下 ★ 就把播放停住是不能接受的
      if (wasPlaying) {
        await video.play();
        await _syncPlaying(true);
      }
      return;
    }
    // 画面与口播都没变（改的是配乐/音量）：只把配乐那一路对齐，画面不动
    await _applyBgm(video.positionMs, force: true);
  }

  /// 上一条采样日志的时刻——排查同步问题时要看得见偏差怎么演变的，
  /// 但每次位置更新都打会把日志刷爆，一秒一条足够
  int _lastTraceMs = -100000;

  void _onMasterPosition(int masterMs) {
    if (_disposed) return;
    if (video.isPlaying && (masterMs - _lastTraceMs).abs() >= 1000) {
      _lastTraceMs = masterMs;
      AppLog.info('同步采样：主时钟 ${masterMs}ms、口播轨 ${voice.positionMs}ms、'
          '偏差 ${voice.positionMs - masterMs}ms、前瞻 ${_seekCostMs}ms');
    }
    _checkPace(masterMs);
    unawaited(_applyBgm(masterMs));
    unawaited(_applySource(masterMs));
  }

  /// 画面轨的走时探针：每一拍走掉的**内容**，对得上真实过去的时间吗。
  ///
  /// 主时钟自己不会变速，但 EDL 段与段之间要打开新文件、精确 seek，这一下
  /// 若卡住，播放器随后会丢帧把落下的补回来——用户看到的就是「画面明显
  /// 加速了」，跟随轨也被一起拽。这种事只在完整播放里才撞得到，靠肉眼盯着
  /// 复现不了，必须留下量得出来的痕迹。
  void _checkPace(int masterMs) {
    final wallMs = _pace.elapsedMilliseconds;
    if (!video.isPlaying) {
      _paceAtMs = masterMs;
      _paceWallMs = wallMs;
      return;
    }
    final wallDelta = wallMs - _paceWallMs;
    // 攒够一段再判，否则单次上报的抖动会淹没真信号
    if (wallDelta < _paceWindowMs) return;
    final contentDelta = masterMs - _paceAtMs;
    _paceAtMs = masterMs;
    _paceWallMs = wallMs;
    final rate = contentDelta / wallDelta;
    if (rate > 1.25 || rate < 0.75) {
      AppLog.warn('画面轨走时异常：${wallDelta}ms 里走掉了 ${contentDelta}ms 内容'
          '（${rate.toStringAsFixed(2)}×），此刻 $masterMs');
    }
  }

  /// 探针基线归零。开播、换源之后都要来一次
  void _resetPace() {
    _paceAtMs = video.positionMs;
    _paceWallMs = _pace.elapsedMilliseconds;
  }

  final Stopwatch _pace = Stopwatch()..start();
  int _paceAtMs = 0;
  int _paceWallMs = 0;
  static const int _paceWindowMs = 400;

  void _onMasterPlaying(bool playing) {
    if (_disposed) return;
    unawaited(_syncPlaying(playing));
    if (playing) {
      // 刚开播：走时探针的基线要归零，否则第一段会拿「从 app 启动算起」
      // 的挂钟去比，报一条没意义的 0.00×
      _resetPace();
      _syncTimer ??= Timer.periodic(syncInterval, (_) => _correctDrift());
    } else {
      _syncTimer?.cancel();
      _syncTimer = null;
    }
  }

  Future<void> _syncPlaying(bool playing) async {
    if (playing) {
      await voice.play();
      if (_bgmCue.source != null) await bgm.play();
      if (_sourceKey != null) await source?.play();
    } else {
      await voice.pause();
      await bgm.pause();
      await source?.pause();
    }
  }

  /// 跟随轨漂了就拉回来。只在偏差超过容许值时动手——每次 seek 都是一次
  /// 可闻的接缝，被采样抖动骗着反复 seek 比漂几十毫秒难受得多。
  ///
  /// **必须往前多 seek 一点**：seek 不是瞬间完成的（真机实测 300~400ms）。
  /// 拿发起那一刻的主时钟当目标，等 seek 落地时主时钟已经走远了同样多——
  /// 于是每纠一次就精确地制造出下一次，声音每半秒被拽一下，听感就是「在
  /// 快进」。真机日志里是稳定的 -400ms 死循环（目标 26333 → 27166 →
  /// 28000，每次都差 -400）。所以目标要按上一次的实测耗时前瞻。
  Future<void> _correctDrift() async {
    if (_disposed || _correcting) return;
    final masterMs = video.positionMs;
    if (needsResync(masterMs: masterMs, followerMs: voice.positionMs)) {
      _correcting = true;
      final before = voice.positionMs;
      final watch = Stopwatch()..start();
      // 停着的时候没有前瞻可言——主时钟不走，多跳一段就是错位
      final lead = video.isPlaying ? _seekCostMs : 0;
      try {
        await voice.seekMs(masterMs + lead);
      } finally {
        watch.stop();
        _correcting = false;
      }
      // 取上一次与这一次的均值，别被某一次的抖动带偏；封顶 1 秒，
      // 免得一次异常的慢 seek 把之后所有纠偏都推到未来
      _seekCostMs =
          (((_seekCostMs + watch.elapsedMilliseconds) / 2).round()).clamp(0, 1000);
      AppLog.info('口播轨偏了 ${before - masterMs}ms，纠回来：'
          '目标 ${masterMs + lead}（前瞻 $lead）、'
          'seek 耗时 ${watch.elapsedMilliseconds}ms、'
          '现在跟随轨 ${voice.positionMs} / 主时钟 ${video.positionMs}');
    }
    final cue = _bgmCue;
    if (cue.source == null) return;
    final want = _plan.bgmAt(masterMs)?.sourceMsAt(masterMs);
    if (want != null &&
        needsResync(masterMs: want, followerMs: bgm.positionMs)) {
      await bgm.seekMs(want);
    }
  }

  /// 原声轨当前挂着哪一段（`源文件@段起点`）；null = 这一刻不出原声
  String? _sourceKey;

  /// 原声轨当前的音量。单独记一份：拖音量滑杆时段没变，只该改音量
  double _sourceVolume = 0;

  /// 素材原声跟着画面走：换段才重新加载与对位，同一段里让它自己播。
  /// 原声是音效，几十毫秒的漂移无所谓——反倒是每帧都 seek 会把它搅碎
  Future<void> _applySource(int masterMs, {bool force = false}) async {
    final track = source;
    if (track == null) return;
    TrackSegment? hit;
    for (final seg in _plan.video) {
      if (seg.covers(masterMs)) {
        hit = seg;
        break;
      }
    }
    final want = (hit == null || hit.volume <= 0.001) ? null : hit;
    final key = want == null ? null : '${want.source}@${want.atMs}';
    final volume = want?.volume ?? 0.0;
    final sameSegment = key == _sourceKey;
    // 音量单独变了（人正在拖那根滑杆）就只改音量——不重新加载，
    // 否则声音会断一下
    if (!force && sameSegment && volume == _sourceVolume) return;
    _sourceKey = key;
    _sourceVolume = volume;
    if (want == null) {
      await track.pause();
      return;
    }
    if (!sameSegment || force) {
      await track.load(want.source);
      await track.seekMs(want.inMs + (masterMs - want.atMs));
    }
    await track.setVolume(volume);
    if (video.isPlaying) await track.play();
  }

  /// 配乐按范围启停。只在**换段/换曲/换音量**时下命令——每帧都 seek 会把
  /// 曲子搅成噪音。
  Future<void> _applyBgm(int masterMs, {bool force = false}) async {
    final cue = bgmCueAt(_plan, masterMs);
    final changedSource = cue.source != _bgmCue.source;
    final changedVolume = cue.volume != _bgmCue.volume;
    if (!force && !changedSource && !changedVolume) return;
    _bgmCue = cue;

    if (cue.source == null) {
      await bgm.pause();
      return;
    }
    if (changedSource || force) {
      await bgm.load(cue.source);
      await bgm.seekMs(cue.inMs);
    }
    await bgm.setVolume(cue.volume);
    if (video.isPlaying) await bgm.play();
  }

  // ——— 以下把控制转发给主时钟，跟随轨随后对齐 ———

  @override
  Future<void> open(String path) => video.open(path);

  @override
  Future<void> play() async {
    await video.play();
    // playingStream 也会触发一次，这里显式来一遍避免首帧那一刻的空档
    await _syncPlaying(true);
  }

  @override
  Future<void> pause() async {
    await video.pause();
    await _syncPlaying(false);
  }

  @override
  Future<void> seekMs(int ms) async {
    await video.seekMs(ms);
    await voice.seekMs(ms);
    await _applyBgm(ms, force: true);
    await _applySource(ms, force: true);
  }

  @override
  Future<bool> playRange(int startMs, int endMs, double fps) async {
    final ok = await video.playRange(startMs, endMs, fps);
    if (!ok) return false;
    await voice.seekMs(startMs);
    await _applyBgm(startMs, force: true);
    await _syncPlaying(true);
    return true;
  }

  @override
  Future<void> clearRange() => video.clearRange();

  @override
  Future<void> stepFrames(int frames, double fps) async {
    await video.stepFrames(frames, fps);
    // 逐帧看画面时不必让声音跟着一帧一帧跳，但位置要对上，
    // 下次按播放才不会从错的地方接上
    await voice.seekMs(video.positionMs);
    await _applyBgm(video.positionMs, force: true);
  }

  @override
  Stream<int> get positionMsStream => video.positionMsStream;

  @override
  Stream<bool> get playingStream => video.playingStream;

  @override
  int get positionMs => video.positionMs;

  @override
  bool get isPlaying => video.isPlaying;

  /// 多轨模式下没有「外挂音轨」这回事——声音本来就在独立的轨上。
  /// 返回 false 让调用方知道不必走那条老路。
  @override
  Future<bool> setExternalAudio(String path) async => false;

  @override
  Future<void> clearExternalAudio() async {}

  @override
  Future<void> dispose() async {
    _disposed = true;
    _syncTimer?.cancel();
    await _positionSub?.cancel();
    await _playingSub?.cancel();
    await voice.dispose();
    await bgm.dispose();
    await source?.dispose();
    await video.dispose();
  }

  /// 画面组件。非 media_kit 的实现（测试替身）返回 null
  Widget? buildVideoWidget() {
    final master = video;
    return master is MediaKitPlaybackController
        ? master.buildVideoWidget()
        : null;
  }
}
