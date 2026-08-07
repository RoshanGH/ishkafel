import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/audio_track_builder.dart';
import '../../core/audio/bgm_plan.dart';
import '../../core/audio/voice_plan.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/export/composed_timeline.dart';
import '../../core/playback/playback_controller.dart';
import '../../core/replacement/replacement_plan.dart';
import 'preview_composer.dart';

/// 造一个能干活的混音器（真实 ffmpeg + 任务自己的工作目录）。
/// 缺省 null 由 main.dart 覆盖；测试注入假实现。
typedef AudioTrackBuilderFactory = AudioTrackBuilder Function(String taskId);

final audioTrackBuilderFactoryProvider =
    Provider<AudioTrackBuilderFactory?>((ref) => null);

/// 预览音轨的状态：给用户看的那一句
enum PreviewAudioState {
  /// 用原片自带的声音（没配乐、也没换音色）
  original,

  /// 正在合成
  building,

  /// 已经挂上合成后的音轨
  ready,

  /// 挂上了，但有配乐没铺上（地址失效 / 网络不通）。声音是能听的，
  /// 只是少了那几段垫乐——与「整条失败」是两回事，不能混为一谈
  degraded,

  /// 合成失败，退回原声
  failed,
}

/// 造一个能干活的预览合成器（真实 ffmpeg + 素材下载）。
/// 缺省 null 表示「不合成画面」——那时预览还是播原片、只挂外挂音轨
typedef PreviewComposerFactory = PreviewComposer Function(String taskId);

final previewComposerFactoryProvider =
    Provider<PreviewComposerFactory?>((ref) => null);

/// 让预览里听到的、**看到的**都是导出后的样子。
///
/// **为什么必须合成一条**：配音是**替换**那几句的原声，配乐是**叠加**在背景上，
/// 两者混在一起只有一个可靠做法——先合出成片那条音轨，再让播放器用它
/// （外挂音轨，画面与声音由同一个播放器对齐，不必另起一个去追同步）。
///
/// **什么时候不合**：没配乐、也没换音色时，原片那条音轨就是正确答案——
/// 不做任何事，零开销，也不损一道音质。
class PreviewAudioController extends ChangeNotifier {
  final PlaybackController playback;
  final AudioTrackBuilderFactory? factory;

  /// 画面合成器。有替换时把画面也拼出来，预览才看得到整体替换与变速；
  /// 为空则退回「播原片 + 挂外挂音轨」（画面永远是原片）
  final PreviewComposerFactory? composerFactory;

  /// 原片路径，没有替换时播它
  String? _sourcePath;

  /// 合成前的等待。拖一次边界会触发几十次改动，逐次合成既浪费又会排成长队。
  final Duration debounce;

  PreviewAudioController({
    required this.playback,
    required this.factory,
    this.composerFactory,
    this.debounce = const Duration(milliseconds: 700),
  });

  /// 成片的时间轴。整体替换会改变时长——播放头要靠它在「时间线（原片）」与
  /// 「播放器（成片）」之间换算
  ComposedTimeline? _timeline;
  ComposedTimeline? get timeline => _timeline;

  /// 现在播的是不是合成出来的片子（而不是原片）
  bool get playingComposed => _composedPath != null;
  String? _composedPath;

  PreviewAudioState _state = PreviewAudioState.original;
  PreviewAudioState get state => _state;

  String? _failure;

  /// 失败原因（已是中文）；没失败时为 null
  String? get failure => _failure;

  Timer? _timer;

  /// 上一次合成用的输入指纹。相同就不重合——切换选中、改标签这类改动
  /// 与声音无关，不该触发几秒的重建。
  String? _builtFingerprint;

  /// 正在合成的那一次的指纹，用于丢弃过期结果
  String? _buildingFingerprint;

  /// 画面合成的进度（已完成段数 / 总段数）。四十多段要跑几分钟，
  /// 只说「稍后就能听到」等于让用户干等着猜还有多久
  int _progressDone = 0;
  int _progressTotal = 0;

  /// 合成进度；没在合成、或者这一次不用合画面时为 null
  (int done, int total)? get progress =>
      _progressTotal > 0 ? (_progressDone, _progressTotal) : null;

  /// 每个任务只建一个合成器：它内部有段落级缓存，每次新建一个等于把缓存
  /// 扔掉，同一批切片会被反复重渲染
  PreviewComposer? _composer;

  void _onProgress(int done, int total) {
    _progressDone = done;
    _progressTotal = total;
    notifyListeners();
  }

  /// 方案有任何变化时调用。与声音无关的变化会被指纹挡掉。
  void update({
    required RenewTask task,
    required List<SemanticUnit> units,
    required Map<int, String> voiceAudio,
    List<UnitReplacement> replacements = const [],
  }) {
    _sourcePath = task.sourcePath;
    final fingerprint = _fingerprintOf(
        task: task,
        units: units,
        voiceAudio: voiceAudio,
        replacements: replacements);
    if (fingerprint == _builtFingerprint || fingerprint == _buildingFingerprint) {
      return;
    }

    _timer?.cancel();
    // 没配乐、没换音色、也没有替换：原片就是正确答案，什么都不做
    final hasReplacement = replacements.any((r) => r.factor > 1 ||
        r.wholeCandidateIds.isNotEmpty ||
        r.shotCandidateIds.values.any((v) => v.isNotEmpty));
    if (task.bgm.segments.isEmpty && task.voices.isEmpty && !hasReplacement) {
      _builtFingerprint = fingerprint;
      _buildingFingerprint = null;
      unawaited(_backToSource());
      _set(PreviewAudioState.original);
      return;
    }

    _timer = Timer(debounce, () {
      unawaited(_build(
          fingerprint: fingerprint,
          task: task,
          units: units,
          voiceAudio: voiceAudio,
          replacements: replacements));
    });
  }

  /// 回到「播原片」：替换全撤掉之后要把播放源换回去，否则还停在上一次
  /// 合成出来的那条片子上
  Future<void> _backToSource() async {
    _timeline = null;
    if (_composedPath != null && _sourcePath != null) {
      _composedPath = null;
      await playback.open(_sourcePath!);
    }
    await playback.clearExternalAudio();
  }

  Future<void> _build({
    required String fingerprint,
    required RenewTask task,
    required List<SemanticUnit> units,
    required Map<int, String> voiceAudio,
    List<UnitReplacement> replacements = const [],
  }) async {
    final make = factory;
    if (make == null) {
      _failure = '未检测到 ffmpeg，预览听到的仍是原片的声音';
      _set(PreviewAudioState.failed);
      return;
    }
    _buildingFingerprint = fingerprint;
    _failure = null;
    _progressDone = 0;
    _progressTotal = 0;
    _set(PreviewAudioState.building);
    try {
      final track = await make(task.id).build(
        sourcePath: task.sourcePath,
        units: units,
        vocalsPath: task.vocalsPath,
        bgm: task.bgm,
        voiceAudio: voiceAudio,
      );
      // 合成期间用户又改了：这一次的结果已经过期，丢掉
      if (_buildingFingerprint != fingerprint) return;
      if (!File(track.path).existsSync()) {
        throw Exception('合成后的音轨文件不存在');
      }

      // 有替换就把画面也拼出来——只挂外挂音轨的话，整体替换那一段
      // 画面还停在原片上，从那儿之后声画全错位
      final composed = await _composeVideo(
          task: task,
          units: units,
          replacements: replacements,
          audioPath: track.path);
      if (_buildingFingerprint != fingerprint) return;
      if (composed != null) {
        _composedPath = composed.videoPath;
        _timeline = composed.timeline;
        await playback.open(composed.videoPath!);
        _builtFingerprint = fingerprint;
        _buildingFingerprint = null;
        _failure =
            track.bgmWarnings.isEmpty ? null : track.bgmWarnings.join('；');
        _set(track.bgmWarnings.isEmpty
            ? PreviewAudioState.ready
            : PreviewAudioState.degraded);
        return;
      }

      final ok = await playback.setExternalAudio(track.path);
      _builtFingerprint = fingerprint;
      _buildingFingerprint = null;
      if (ok) {
        // 部分配乐没铺上时照样能听，但要说清楚是哪一段——只说「合成失败」
        // 会让人以为整条音轨都没了
        _failure = track.bgmWarnings.isEmpty ? null : track.bgmWarnings.join('；');
        _set(track.bgmWarnings.isEmpty
            ? PreviewAudioState.ready
            : PreviewAudioState.degraded);
      } else {
        _failure = '这个播放器挂不了外挂音轨，预览听到的仍是原片的声音';
        _set(PreviewAudioState.failed);
      }
    } catch (e) {
      AppLog.warn('预览音轨合成失败（taskId=${task.id}）：$e');
      if (_buildingFingerprint != fingerprint) return;
      _buildingFingerprint = null;
      _failure = '预览音轨合成失败，听到的仍是原片的声音：$e';
      _set(PreviewAudioState.failed);
    }
  }

  /// 有替换时合成画面；没有替换、或者没装合成器时返回 null（退回外挂音轨）
  Future<ComposedPreview?> _composeVideo({
    required RenewTask task,
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    required String audioPath,
  }) async {
    final makeComposer = composerFactory;
    if (makeComposer == null || replacements.isEmpty) return null;
    final composer = _composer ??= makeComposer(task.id);
    composer.onProgress = _onProgress;
    try {
      final result = await composer.compose(
        sourcePath: task.sourcePath,
        units: units,
        replacements: replacements,
        audioPath: audioPath,
      );
      return result.videoPath == null ? null : result;
    } catch (e) {
      // 画面合不出来时退回「原片 + 外挂音轨」：声音仍然是对的，
      // 只是看不到替换效果，比整个预览黑掉强
      AppLog.warn('预览画面合成失败，退回原片画面（taskId=${task.id}）：$e');
      return null;
    }
  }

  /// 忘掉上一次的结果，让下一次 [sync] 真的重新合成一遍。
  ///
  /// 「重试」按钮走这里：不清指纹的话，方案没变就直接跳过了，重试等于没点
  void invalidate() {
    _builtFingerprint = null;
    _buildingFingerprint = null;
    _failure = null;
  }

  void _set(PreviewAudioState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }

  /// 影响声音的东西：配乐、配音、以及单元边界（边界变了每段的时长就变了）。
  /// 画面替换、标签、选中状态都不在其中。
  static String _fingerprintOf({
    required RenewTask task,
    required List<SemanticUnit> units,
    required Map<int, String> voiceAudio,
    List<UnitReplacement> replacements = const [],
  }) {
    final picks = [
      for (final r in replacements)
        '${r.mode.name}:${r.wholePreviewId}:'
            '${r.shotPreviewIds.entries.map((e) => '${e.key}-${e.value}').join('|')}',
    ].join(',');
    final bgm = [
      for (final s in task.bgm.segments)
        '${s.startUnit}-${s.endUnit}-${s.previewMaterial.id}-${s.volume}',
    ].join(',');
    final voices = [
      for (final a in task.voices.assignments)
        '${a.unitIndex}-${a.voice.id}-${voiceAudio[a.unitIndex] ?? ''}',
    ].join(',');
    final bounds = [for (final u in units) '${u.startMs}-${u.endMs}'].join(',');
    // 预览版换了也要重合——那正是「预览播哪一个候选」的开关
    return '$bgm|$voices|$bounds|${task.vocalsPath ?? ''}|$picks';
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// 状态对应的那句话。不写出来的话，用户不知道自己听到的到底是原声还是成品。
///
/// [progress] 是画面合成的进度。一条 96 秒、51 个镜头的片子要跑几分钟，
/// 一句「稍后就能听到」挂在那里，用户没法判断是在干活还是卡死了。
String? previewAudioNotice(
  PreviewAudioState state,
  String? failure, {
  (int done, int total)? progress,
}) =>
    switch (state) {
      PreviewAudioState.original => null,
      PreviewAudioState.building => progress == null
          ? '正在合成预览音轨（配乐/配音），稍后就能听到'
          : '正在合成预览（第 ${progress.$1}/${progress.$2} 段）'
              '——只合改动过的部分，下次进来直接就能播',
      PreviewAudioState.ready => null,
      // 声音是能听的，只是少了几段垫乐——说成「不可用」会让人以为白干了
      // 底层的原因已经是人话了，这里只补一句「其余声音正常」——
      // 再套一层解释会让曲名重复出现，长得没法读
      PreviewAudioState.degraded =>
        failure == null ? null : '$failure。其余声音正常',
      PreviewAudioState.failed => failure ?? '预览音轨不可用，听到的仍是原片的声音',
    };

/// 有配乐或配音、但没有分离出来的人声轨时的提醒。
///
/// 这种情况下新配乐只能叠在原声上，原片自带的背景音还在——两首曲子一起响。
/// 用户听到的东西不对，必须说清是为什么。
String? missingVocalsNotice(BgmPlan bgm, VoicePlan voices, String? vocalsPath) {
  if (bgm.segments.isEmpty) return null;
  if (vocalsPath != null && File(vocalsPath).existsSync()) return null;
  return '没有分离出纯人声轨，新配乐会与原片自带的背景音叠在一起。'
      '装好人声分离工具后重新分析可解决';
}
