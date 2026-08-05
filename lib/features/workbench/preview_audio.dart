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
import '../../core/playback/playback_controller.dart';

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

  /// 合成失败，退回原声
  failed,
}

/// 让预览里听到的就是导出后的声音。
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

  /// 合成前的等待。拖一次边界会触发几十次改动，逐次合成既浪费又会排成长队。
  final Duration debounce;

  PreviewAudioController({
    required this.playback,
    required this.factory,
    this.debounce = const Duration(milliseconds: 700),
  });

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

  /// 方案有任何变化时调用。与声音无关的变化会被指纹挡掉。
  void update({
    required RenewTask task,
    required List<SemanticUnit> units,
    required Map<int, String> voiceAudio,
  }) {
    final fingerprint = _fingerprintOf(
        task: task, units: units, voiceAudio: voiceAudio);
    if (fingerprint == _builtFingerprint || fingerprint == _buildingFingerprint) {
      return;
    }

    _timer?.cancel();
    // 没配乐也没换音色：原片那条音轨就是对的，什么都不做
    if (task.bgm.segments.isEmpty && task.voices.isEmpty) {
      _builtFingerprint = fingerprint;
      _buildingFingerprint = null;
      unawaited(playback.clearExternalAudio());
      _set(PreviewAudioState.original);
      return;
    }

    _timer = Timer(debounce, () {
      unawaited(_build(
          fingerprint: fingerprint,
          task: task,
          units: units,
          voiceAudio: voiceAudio));
    });
  }

  Future<void> _build({
    required String fingerprint,
    required RenewTask task,
    required List<SemanticUnit> units,
    required Map<int, String> voiceAudio,
  }) async {
    final make = factory;
    if (make == null) {
      _failure = '未检测到 ffmpeg，预览听到的仍是原片的声音';
      _set(PreviewAudioState.failed);
      return;
    }
    _buildingFingerprint = fingerprint;
    _failure = null;
    _set(PreviewAudioState.building);
    try {
      final path = await make(task.id).build(
        sourcePath: task.sourcePath,
        units: units,
        vocalsPath: task.vocalsPath,
        bgm: task.bgm,
        voiceAudio: voiceAudio,
      );
      // 合成期间用户又改了：这一次的结果已经过期，丢掉
      if (_buildingFingerprint != fingerprint) return;
      if (!File(path).existsSync()) {
        throw Exception('合成后的音轨文件不存在');
      }
      final ok = await playback.setExternalAudio(path);
      _builtFingerprint = fingerprint;
      _buildingFingerprint = null;
      if (ok) {
        _set(PreviewAudioState.ready);
      } else {
        _failure = '这个播放器挂不了外挂音轨，预览听到的仍是原片的声音';
        _set(PreviewAudioState.failed);
      }
    } catch (e) {
      AppLog.warn('预览音轨合成失败（taskId=${task.id}）：$e');
      if (_buildingFingerprint != fingerprint) return;
      _buildingFingerprint = null;
      _failure = '预览音轨合成失败，听到的仍是原片的声音';
      _set(PreviewAudioState.failed);
    }
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
  }) {
    final bgm = [
      for (final s in task.bgm.segments)
        '${s.startShot}-${s.endShot}-${s.material.id}',
    ].join(',');
    final voices = [
      for (final a in task.voices.assignments)
        '${a.unitIndex}-${a.voice.id}-${voiceAudio[a.unitIndex] ?? ''}',
    ].join(',');
    final bounds = [for (final u in units) '${u.startMs}-${u.endMs}'].join(',');
    return '$bgm|$voices|$bounds|${task.vocalsPath ?? ''}';
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// 状态对应的那句话。不写出来的话，用户不知道自己听到的到底是原声还是成品。
String? previewAudioNotice(PreviewAudioState state, String? failure) =>
    switch (state) {
      PreviewAudioState.original => null,
      PreviewAudioState.building => '正在合成预览音轨（配乐/配音），稍后就能听到',
      PreviewAudioState.ready => null,
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
