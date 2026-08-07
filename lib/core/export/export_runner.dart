import 'dart:io';

import 'package:path/path.dart' as p;

import '../audio/bgm_plan.dart';
import '../audio/voice_plan.dart';
import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import '../models/semantic_unit.dart';
import '../replacement/replacement_plan.dart';
import '../audio/audio_track_builder.dart';
import 'export_commands.dart';
import 'speed_fit.dart';
import 'export_plan.dart';

/// 一条成片的导出结果
class ExportOutcome {
  final int index;

  /// 成功时是成片路径；失败时为 null
  final String? path;

  /// 失败原因（已是中文）；成功时为 null
  final String? failure;

  const ExportOutcome({required this.index, this.path, this.failure});

  bool get ok => path != null;
}

/// 导出进度：正在做第几条、总共几条、这一刻在做什么
typedef ExportProgress = void Function(int done, int total, String what);

/// 矩阵导出：把替换方案摊成若干条成片，逐条用 ffmpeg 合成。
///
/// **画面来自候选素材或原片，声音一律来自原片（或换音色后的配音）**：产品要的
/// 是「结构相同但画面全新」，所以候选素材自带的旁白要丢掉，只取它的画面。
///
/// 三处刻意的复用，不然十条成片要跑上一个钟头：
/// - **声音只做一遍**：所有组合的声音完全相同（画面才是变量）；
/// - **原片段只切一遍**：同一个单元的原片画面会在多条组合里重复出现；
/// - **素材只下载一遍**：同一条候选也会在多条组合里重复出现。
class ExportRunner {
  final ProcessRunner run;

  /// 中间产物目录（切片、下载的素材、清单文件）
  final Directory workDir;

  /// 下载一条候选素材到本地，返回落地路径。注入而不是内建 http：
  /// 这一层要能在不联网的情况下测。
  final Future<String> Function(int candidateId) fetchMaterial;

  /// 把一条配乐解析成本地可读的地址（见 [AudioTrackBuilder.resolveBgm]）。
  /// 不注入时退回素材自带的签名地址——它随时可能已经失效。
  final Future<String> Function(BgmMaterial material)? resolveBgm;

  /// 读一条本地素材有多长（毫秒）。镜头替换要按它算变速倍率；读不出来
  /// 返回 null，那时退回裁/冻帧而不是瞎猜倍率。
  final Future<int?> Function(String path)? probeDurationMs;

  ExportRunner({
    required this.run,
    required this.workDir,
    required this.fetchMaterial,
    this.resolveBgm,
    this.probeDurationMs,
  });

  /// 变速越界的镜头替换（见 [SpeedFit]）。整体替换不参与——那一层是画面和
  /// 声音一起换、时长随候选，本来就不变速。
  Future<String?> _speedBlocker(List<ExportCombination> combos) async {
    final probe = probeDurationMs;
    if (probe == null) return null;

    final seen = <String>{};
    final bad = <String>[];
    for (final combo in combos) {
      for (final segment in combo.segments) {
        final id = segment.candidateId;
        if (id == null || segment.shotIndex == null) continue;
        final key = '${segment.startMs}_${segment.endMs}_$id';
        if (!seen.add(key)) continue;

        final int? candidateMs;
        try {
          candidateMs = await probe(await fetchMaterial(id));
        } catch (e) {
          AppLog.warn('读不出候选 $id 的时长，这一段退回裁/冻帧：$e');
          continue;
        }
        // 读不出来就不猜倍率
        if (candidateMs == null || candidateMs <= 0) continue;
        final why = SpeedFit.rejectReason(
            candidateMs: candidateMs, slotMs: segment.durationMs);
        if (why == null) continue;
        bad.add('U${segment.unitIndex + 1} 的 S${segment.shotIndex! + 1}：$why');
      }
    }
    return bad.isEmpty ? null : bad.join('\n');
  }

  /// 出片前的拦截：有任何一条会让成片**静默出错**就返回原因，否则 null。
  ///
  /// 这几条的共同点是「导出来的片子看着正常，其实不是用户要的」——
  /// 用户发现不了，所以宁可不导。
  static String? _deliveryBlocker({
    required BgmPlan bgm,
    required String? vocalsPath,
    required VoicePlan voices,
    required Map<int, String> voiceAudio,
  }) {
    // 有配乐却没有分离出来的人声轨：新配乐只能叠在原混音上，原片自带的
    // 背景音还在，成片里两首曲子一起响
    if (bgm.segments.isNotEmpty &&
        (vocalsPath == null || !File(vocalsPath).existsSync())) {
      return '这条片子有配乐，但没有分离出来的纯人声轨——直接导出会让新配乐'
          '叠在原片背景音上（两首曲子一起响）。请先装好分离工具并重新分析';
    }

    // 选了音色却没生成配音：那一段会静默用回原声
    final missing = <String>[];
    for (final index in voices.assignedUnits) {
      final path = voiceAudio[index];
      if (path == null || !File(path).existsSync()) {
        missing.add('U${index + 1}');
      }
    }
    if (missing.isNotEmpty) {
      return '${missing.join('、')} 选了音色但还没生成配音，'
          '直接导出这几段会是原声。请先点「生成配音」';
    }
    return null;
  }

  /// 导出全部组合到 [outputDir]。
  ///
  /// 一条失败不拖累其余：失败的那条记下原因继续跑下一条——十条里坏一条，
  /// 重跑那一条就行，没道理整批作废。
  Future<List<ExportOutcome>> exportAll({
    required String sourcePath,
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    required Directory outputDir,
    BgmPlan bgm = BgmPlan.empty,
    Map<int, String> voiceAudio = const {},

    /// 换音色方案。用来核对「选了音色的单元是不是都生成了配音」——
    /// 少了会静默导出原声
    VoicePlan voices = VoicePlan.empty,

    /// 分离出来的纯人声轨；被配乐覆盖的段落要用它，否则新旧背景一起响
    String? vocalsPath,
    int limit = ReplacementPlan.maxCombinations,
    ExportProgress? onProgress,
  }) async {
    final combos = ExportPlanner.enumerate(
        units: units, replacements: replacements, limit: limit);
    if (combos.isEmpty) return const [];

    workDir.createSync(recursive: true);
    outputDir.createSync(recursive: true);
    final total = combos.length;

    // 出片前先把「会静默做错」的几件事拦掉。
    //
    // **预览可以降级，成片不行**：预览时人还在编辑、听得出来；成片少一段
    // 垫乐、少一句换过的配音、或者新旧背景叠在一起，交付出去没人会发现。
    // 宁可这一次导不出来，也不能给一条看起来正常、其实是错的片子。
    // 镜头替换的候选必须能在 0.8×~2.0× 内对齐坑位。一次把所有越界的点名，
    // 免得用户改一个导一次
    final tooFar = await _speedBlocker(combos);
    final blocker = tooFar ??
        _deliveryBlocker(
            bgm: bgm,
            vocalsPath: vocalsPath,
            voices: voices,
            voiceAudio: voiceAudio);
    if (blocker != null) {
      AppLog.warn('导出前置检查未通过：$blocker');
      return [
        for (final c in combos)
          ExportOutcome(index: c.index, failure: blocker),
      ];
    }

    onProgress?.call(0, total, '准备声音');
    final AudioTrack track;
    try {
      track = await AudioTrackBuilder(
        run: run,
        workDir: workDir,
        resolveBgm: resolveBgm,
      ).build(
        sourcePath: sourcePath,
        units: units,
        vocalsPath: vocalsPath,
        bgm: bgm,
        voiceAudio: voiceAudio,
      );
    } catch (e) {
      AppLog.warn('导出：声音合成失败：$e');
      // 声音是所有组合共用的，它挂了就没有哪条能成——如实把同一条原因给每一条
      return [
        for (final c in combos)
          ExportOutcome(index: c.index, failure: '声音合成失败：$e'),
      ];
    }

    // 配乐没铺上就是错的成片。预览那边是降级，这里必须失败
    if (track.bgmWarnings.isNotEmpty) {
      final why = track.bgmWarnings.join('；');
      AppLog.warn('导出中止：$why');
      return [
        for (final c in combos)
          ExportOutcome(
              index: c.index, failure: '配乐没能铺上，已中止导出：$why'),
      ];
    }

    final clips = <String, String>{}; // 段落指纹 → 已渲染的画面切片
    final out = <ExportOutcome>[];
    for (final combo in combos) {
      onProgress?.call(out.length, total, '第 ${combo.index} 条');
      try {
        final path = await _composeOne(
          combo: combo,
          sourcePath: sourcePath,
          audio: track.path,
          outputDir: outputDir,
          clips: clips,
        );
        out.add(ExportOutcome(index: combo.index, path: path));
      } catch (e) {
        AppLog.warn('导出：第 ${combo.index} 条失败：$e');
        out.add(ExportOutcome(index: combo.index, failure: '$e'));
      }
    }
    onProgress?.call(total, total, '完成');
    return List.unmodifiable(out);
  }

  /// 拼一条成片：逐段渲染画面 → concat → 与共用的声音合成
  Future<String> _composeOne({
    required ExportCombination combo,
    required String sourcePath,
    required String audio,
    required Directory outputDir,
    required Map<String, String> clips,
  }) async {
    final parts = <String>[];
    for (final segment in combo.segments) {
      parts.add(await _renderSegment(segment, sourcePath, clips));
    }

    final listFile = File(p.join(workDir.path, 'concat_${combo.index}.txt'))
      ..writeAsStringSync(ExportCommands.concatList(parts));
    final silent = p.join(workDir.path, 'video_${combo.index}.mp4');
    await _ffmpeg(
        ExportCommands.concat(listFile: listFile.path, out: silent), '拼接画面');

    final out = p.join(outputDir.path, '变体${combo.index}.mp4');
    await _ffmpeg(
        ExportCommands.mux(video: silent, audio: audio, out: out), '画面与声音合成');
    return out;
  }

  /// 渲染一段画面。同一段在多条组合里会重复出现，按指纹缓存，只做一遍。
  Future<String> _renderSegment(
    ExportSegment segment,
    String sourcePath,
    Map<String, String> clips,
  ) async {
    final key = '${segment.startMs}_${segment.endMs}_${segment.candidateId}';
    final hit = clips[key];
    if (hit != null) return hit;

    final out = p.join(workDir.path, 'clip_$key.mp4');
    if (segment.isOriginal) {
      await _ffmpeg(
        ExportCommands.trimOriginalVideo(
          source: sourcePath,
          startMs: segment.startMs,
          endMs: segment.endMs,
          out: out,
        ),
        'U${segment.unitIndex + 1} 的原片画面',
      );
    } else {
      final material = await fetchMaterial(segment.candidateId!);
      // 镜头替换按倍率变速；整体替换与探不出时长的退回裁/冻帧
      final candidateMs = segment.shotIndex == null
          ? null
          : await _probeQuietly(material);
      await _ffmpeg(
        ExportCommands.fitCandidateVideo(
          input: material,
          durationMs: segment.durationMs,
          candidateDurationMs: candidateMs,
          out: out,
        ),
        'U${segment.unitIndex + 1} 的替换画面',
      );
    }
    clips[key] = out;
    return out;
  }

  Future<int?> _probeQuietly(String path) async {
    final probe = probeDurationMs;
    if (probe == null) return null;
    try {
      final ms = await probe(path);
      return ms != null && ms > 0 ? ms : null;
    } catch (e) {
      AppLog.warn('读不出 $path 的时长，这一段退回裁/冻帧：$e');
      return null;
    }
  }

  Future<void> _ffmpeg(List<String> args, String what) async {
    final result = await run('ffmpeg', args);
    if (result.exitCode != 0) {
      // ffmpeg 的 stderr 动辄几百行，只留最后几行——真正的原因总在末尾
      final stderr = '${result.stderr}'.trim().split('\n');
      final tail = stderr.length > 3 ? stderr.sublist(stderr.length - 3) : stderr;
      throw Exception('$what 失败：${tail.join(' / ')}');
    }
  }
}
