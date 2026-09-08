import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/foundation.dart';

import '../../core/audio/bgm_plan.dart';
import '../../core/audio/voice_plan.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/playback/multitrack_playback.dart';
import '../../core/playback/track_plan.dart';
import '../../core/playback/track_plan_builder.dart';
import '../../core/replacement/replacement_plan.dart';
import '../../core/playback/gap_clip.dart';
import '../../core/ffmpeg/media_spec.dart';
import '../picking/picked_media_cache.dart';
import 'speed_fitter.dart';

/// 把「替换方案」推成「三条轨」，并交给多轨播放器。
///
/// 取代了原来那套「ffmpeg 预合成 + 外挂音轨」：现在换个候选、换首配乐、拉个
/// 音量都是**改一个字符串再让播放器换源**，不生成任何中间文件。唯一还要等的
/// 是镜头替换的变速切片（见 [SpeedFitter]），而它只渲染标了 ★ 的那一条。
class PreviewTracks extends ChangeNotifier {
  final MultitrackPlayback playback;

  /// 已选素材的本地固定（画面）与配乐的本地固定。取不到路径的那一段
  /// 当没选——预览宁可播原片，也不能播一个空洞
  final PickedMediaCache? materials;
  final PickedMediaCache? bgmMedia;
  final SpeedFitter? speedFitter;

  /// 给「还没挑素材」的那几段垫黑场。为 null（测试环境没有数据目录）时
  /// 照旧留洞——位置会错，但 Edl 会打警告，不会无声无息
  final GapClip? gapClip;

  /// 已经垫好的：单元下标 → 黑场文件
  final Map<int, String> _gaps = {};

  /// 把一条素材分离成纯人声。为 null 表示这台机器上分不了——那时配乐会和
  /// 素材原声叠在一起，由界面如实提示
  final Future<String?> Function(String materialPath)? separateMaterial;

  TrackPlan _plan = TrackPlan.empty;
  String? _lastKey;
  bool _disposed = false;

  PreviewTracks({
    required this.playback,
    this.materials,
    this.bgmMedia,
    this.speedFitter,
    this.gapClip,
    this.separateMaterial,
  }) {
    speedFitter?.addListener(_onFitterChanged);
  }

  TrackPlan get plan => _plan;

  /// 这一刻要不要告诉用户「还在准备」。为 null 表示一切就绪，不该有横幅——
  /// 多轨播放本来就不需要等合成，只有变速切片会花几秒
  String? get notice {
    final pending = speedFitter?.pending ?? 0;
    if (pending > 0) {
      return '正在准备 $pending 段替换镜头的变速画面，其余部分已经能播';
    }
    if (_plan.bgmMissing.isNotEmpty) return _plan.bgmMissing.join('；');
    // 还没挑素材的那几段：**不等人播到那儿才说**。它们在成片里占着位置却
    // 没有画面，人一按播放就会在那儿停住——先把话说在前面，并点名是哪几段
    if (_plan.unplayable.isNotEmpty) {
      final names =
          _plan.unplayable.map((s) => 'U${s.unitIndex + 1}').join('、');
      return '$names 还没选素材，这几段放不了——去「替换素材」给它们挑，'
          '或者把它们删掉';
    }
    return null;
  }

  /// 成片时刻 → 原片时刻。时间线画的是原片切分，播放头要靠它换算回去
  int toSourceMs(int composedMs) {
    for (final segment in _plan.video) {
      if (!segment.covers(composedMs)) continue;
      // 整体替换那一段没有对应的原片时刻，就近落在这一段的起点
      return segment.sourceMsAt(composedMs);
    }
    return composedMs;
  }

  /// 方案有任何变化时调用。与画面/声音无关的改动会被指纹挡掉。
  /// 原片的预览代理。null 表示还没生成好，这一轮先播原片
  String? proxyPath;

  Future<void> update({
    required RenewTask task,
    required List<SemanticUnit> units,
    required Map<int, String> voiceAudio,
    List<UnitReplacement> replacements = const [],
  }) async {
    // 变速切片要按新方案补齐；补好了会回调，那时再重建一次
    unawaited(speedFitter?.sync(
      units: units,
      replacements: replacements,
      materialPathOf: (id) => materials?.localPathOf(id),
    ));

    // 铺了配乐的整体替换段，后台把素材分离成纯人声；出结果了再重推一次。
    // **不等它**——分离要十几秒，预览为此卡住是不可接受的
    unawaited(_ensureMaterialVocals(
        task: task, units: units, replacements: replacements));

    var plan = _build(
      task: task,
      units: units,
      voiceAudio: voiceAudio,
      replacements: replacements,
    );
    // 还没挑素材的那几段要垫上黑场，否则 EDL 把洞压掉、后面全部提前。
    // 已经垫好的这一轮就用上；没垫好的后台去渲，渲完再推一次
    if (await _ensureGaps(plan, units)) {
      plan = _build(
        task: task,
        units: units,
        voiceAudio: voiceAudio,
        replacements: replacements,
      );
    }
    final key = _keyOf(plan);
    if (key == _lastKey) return;
    _lastKey = key;
    _plan = plan;
    await playback.setPlan(plan);
    _notify();
  }

  /// 给放不了的那几段补黑场。**同步能拿到的当轮就用**（盘上已有），
  /// 缺的丢后台渲，渲完重推一次。返回 true 表示这一轮的方案要重算
  Future<bool> _ensureGaps(TrackPlan plan, List<SemanticUnit> units) async {
    final filler = gapClip;
    if (filler == null || plan.unplayable.isEmpty) return false;
    final spec = await _gapSpec();
    var changed = false;
    for (final span in plan.unplayable) {
      if (_gaps.containsKey(span.unitIndex)) continue;
      final ms = span.endMs - span.startMs;
      final ready = filler.existing(durationMs: ms, spec: spec);
      if (ready != null) {
        _gaps[span.unitIndex] = ready;
        changed = true;
        continue;
      }
      unawaited(filler.render(durationMs: ms, spec: spec).then((path) {
        if (path == null) return;
        _gaps[span.unitIndex] = path;
        _lastKey = null; // 强制下一轮重推
        _notify();
      }));
    }
    return changed;
  }

  MediaSpec? _gapSpecCache;
  bool _gapSpecResolved = false;

  Future<MediaSpec?> _gapSpec() async {
    if (_gapSpecResolved) return _gapSpecCache;
    _gapSpecResolved = true;
    try {
      _gapSpecCache = await speedFitter?.targetSpec?.call();
    } on Object {
      _gapSpecCache = null;
    }
    return _gapSpecCache;
  }

  /// 已经分离好的素材人声（素材路径 → 人声轨）。异步分离在后台跑，
  /// 出结果了再重推一次轨道——预览不能为了等分离先卡住
  final Map<String, String> materialVocals = {};

  /// 给「铺了配乐的整体替换段」准备纯人声。已经分过的不再分
  Future<void> _ensureMaterialVocals({
    required RenewTask task,
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
  }) async {
    final separate = separateMaterial;
    if (separate == null || task.bgm.segments.isEmpty) return;
    var changed = false;
    for (var i = 0; i < units.length && i < replacements.length; i++) {
      final replacement = replacements[i];
      if (replacement.mode != ReplacementMode.whole) continue;
      if (!task.bgm.segments.any((s) => s.covers(i))) continue;
      final id = replacement.wholePreviewId ??
          (replacement.wholeCandidateIds.isEmpty
              ? null
              : replacement.wholeCandidateIds.first);
      if (id == null) continue;
      final path = materials?.localPathOf(id);
      if (path == null || materialVocals.containsKey(path)) continue;
      final vocals = await separate(path);
      if (_disposed) return;
      if (vocals != null) {
        materialVocals[path] = vocals;
        changed = true;
      }
    }
    // 分出来了就重推一次轨道，换成纯人声
    if (changed && !_disposed) _lastKey = null;
  }

  TrackPlan _build({
    required RenewTask task,
    required List<SemanticUnit> units,
    required Map<int, String> voiceAudio,
    required List<UnitReplacement> replacements,
  }) {
    // 时长取自落地记录（挑素材时探过一次，随任务存着），不必再 ffprobe
    final durations = {
      for (final m in task.pickedMaterials)
        if (m.durationMs != null) m.id: m.durationMs!,
    };
    final local = <int, LocalMaterial>{};
    for (final m in task.pickedMaterials) {
      final path = materials?.localPathOf(m.id);
      if (path == null) continue;
      local[m.id] = LocalMaterial(path: path, durationMs: durations[m.id]);
    }
    final bgmPaths = <int, String>{
      for (final material in task.bgm.materials)
        material.id: ?bgmMedia?.localPathOf(material.id),
    };

    return TrackPlanBuilder.build(
      // 画面走代理（规格统一，接缝处不必重建解码器）；代理还没生成好就先播
      // 原片。声音那一路始终读原片——音频解码不吃硬件，没理由多绕一层
      sourcePath: proxyPath ?? task.sourcePath,
      audioSourcePath: task.sourcePath,
      units: units,
      replacements: replacements,
      materials: local,
      speedFitted: speedFitter?.fitted ?? const {},
      vocalsPath: task.vocalsPath,
      voiceAudio: voiceAudio,
      bgm: task.bgm,
      bgmPaths: bgmPaths,
      materialVocals: materialVocals,
      gapClips: _gaps,
    );
  }

  /// 轨道方案的指纹。相同就不换源——换源会让播放器重新打开文件，
  /// 有一次可见的闪
  static String _keyOf(TrackPlan plan) => [
        for (final s in plan.video) '${s.atMs}:${s.durationMs}:${s.source}:${s.inMs}',
        '|',
        for (final s in plan.voice) '${s.atMs}:${s.durationMs}:${s.source}:${s.inMs}',
        '|',
        for (final s in plan.bgm)
          '${s.clip.atMs}:${s.clip.durationMs}:${s.clip.source}:${s.volume}',
      ].join(',');

  void _onFitterChanged() {
    _notify();
    // 变速切片好了：让上层带着最新方案再推一次
    onNeedsRebuild?.call();
  }

  /// 变速切片就绪时回调，让上层用最新方案重建一次轨道
  VoidCallback? onNeedsRebuild;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    speedFitter?.removeListener(_onFitterChanged);
    super.dispose();
  }
}

/// 把素材分离成纯人声的能力。**null 表示这台机器上分不了**（没装工具）——
/// 界面据此如实说明「配乐会和素材原声叠在一起」，而不是让用户对着一条
/// 听起来不对的预览发呆。缺省是 null，真实实现在 main.dart 里装配。
///
/// 放在 features 层而不是 core：riverpod 会把 Flutter 拖进依赖树，
/// 而 core/audio 是 CLI 也要用的——`dart build cli` 会在 FFI 那层直接崩
/// 带 taskId 是因为派生产物也按项目存：分离结果落在 `vocals/<taskId>/`，
/// 删任务时一起走
final materialSeparatorProvider = Provider<
    Future<String?> Function(String taskId, String materialPath)?>(
  (ref) => null,
);

/// 一条提示要说清两件事：**为什么**声音不对，以及**做什么**才能好。
/// [retryable] 为真时界面给一个「重新分离」的按钮
typedef VocalsNotice = ({String text, bool retryable});

/// 有配乐或配音、但没有分离出来的人声轨时的提醒。
///
/// 这种情况下新配乐只能叠在原声上，原片自带的背景音还在——两首曲子一起响。
/// 用户听到的东西不对，必须说清是为什么。
///
/// **这条提示以前是撒谎的**（真机事故 2026-09-04）：它只看人声轨文件在不在，
/// 却一律归因到「工具没装」、一律劝人「重新分析」。用户早把工具装齐了，
/// 「设置 → 关于」也如实显示已安装，而重新分析命中缓存后直接返回、走不到
/// 分离那一步——他照做一百遍也好不了。所以这里按**真实原因**分叉，
/// 并且只给真能解决问题的出口。
///
/// [isBlank] 是空白任务：它没有原片、也就没有原片人声轨，但**它的声音全部
/// 来自替换素材**，而素材是逐条分离的（见 [MaterialVocalCache]）。所以这条
/// 提示对它不成立——除非机器上压根没装分离工具，[canSeparate] 就是为此。
VocalsNotice? missingVocalsNotice(
    BgmPlan bgm, VoicePlan voices, String? vocalsPath,
    {bool isBlank = false, bool canSeparate = true}) {
  if (bgm.segments.isEmpty) return null;
  if (isBlank) {
    // 空白任务的每一段都是整体替换，声音来自素材，逐条分离即可
    if (canSeparate) return null;
    return (
      text: '这台机器上没有装人声分离工具，配乐会和素材自带的声音叠在一起。'
          '去「设置 → 运行环境」装一下就好',
      retryable: false,
    );
  }
  if (vocalsPath != null && File(vocalsPath).existsSync()) return null;
  // 工具真没装：指路去装。重试没有意义，装完才有得谈
  if (!canSeparate) {
    return (
      text: '这台机器上没有装人声分离工具，新配乐会与原片自带的背景音叠在一起。'
          '去「设置 → 运行环境」装一下就好',
      retryable: false,
    );
  }
  // 工具是好的，缺的只是这条片子自己的那份人声轨——分一次就有了。
  // 不许再提「装工具」：人家已经装好了，再劝一遍只会让他以为是自己没装对
  return (
    text: '这条片子的纯人声轨还没有，新配乐会与原片自带的背景音叠在一起。'
        '重新分离一次就好',
    retryable: true,
  );
}
