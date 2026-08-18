import 'dart:io';

import 'package:path/path.dart' as p;

import '../analysis/providers.dart' show AsrSentence;
import '../audio/bgm_plan.dart';
import '../audio/voice_plan.dart';
import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import '../models/semantic_unit.dart';
import '../replacement/replacement_plan.dart';
import '../audio/audio_track_builder.dart';
import '../subtitle/subtitle_overlay.dart';
import '../subtitle/subtitle_rasterizer.dart';
import '../subtitle/subtitle_style.dart';
import 'export_commands.dart';
import 'export_plan.dart';
import 'export_spec.dart';

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

  /// 把一条替换素材分离成纯人声。整体替换的段落铺了配乐时要用它——
  /// 素材自带的背景音留着的话，它和新配乐会两首曲子一起响
  final Future<String?> Function(String materialPath)? separateMaterial;

  /// 出多大、多清楚的缺省值。按次导出可以用 exportAll/exportCombinations
  /// 的 [spec] 参数盖掉——同一个 runner 可能先导一版 1080 再导一版 720
  final ExportSpec defaultSpec;

  /// 读一条本地素材有多长（毫秒）。镜头替换要按它算变速倍率；读不出来
  /// 返回 null，那时退回裁/冻帧而不是瞎猜倍率。
  final Future<int?> Function(String path)? probeDurationMs;

  final SubtitleStyle subtitleStyle;

  /// 字幕图渲染器（系统渲字）。测试注入假实现
  final SubtitleRasterizer rasterizer;

  ExportRunner({
    required this.run,
    required this.workDir,
    required this.fetchMaterial,
    this.resolveBgm,
    this.separateMaterial,
    this.probeDurationMs,
    this.subtitleStyle = SubtitleStyle.standard,
    SubtitleRasterizer? rasterizer,
    this.defaultSpec = ExportSpec.standard,
  }) : rasterizer = rasterizer ?? SubtitleRasterizer();

  /// 出片前的拦截：有任何一条会让成片**静默出错**就返回原因，否则 null。
  ///
  /// 这几条的共同点是「导出来的片子看着正常，其实不是用户要的」——
  /// 用户发现不了，所以宁可不导。
  static String? _deliveryBlocker({
    required BgmPlan bgm,
    required String? vocalsPath,
    required VoicePlan voices,
    required Map<int, String> voiceAudio,
    String? sourcePath,
    List<UnitReplacement> replacements = const [],
  }) {
    // 整体替换用的是候选素材自己的口播，换音色用的是 TTS 合成的口播——
    // 同一个单元两者矛盾，静默取其一正是用户反对的
    final conflict = [
      for (final index in voices.assignedUnits)
        if (index < replacements.length &&
            replacements[index].mode == ReplacementMode.whole &&
            replacements[index].wholeCandidateIds.isNotEmpty)
          'U${index + 1}',
    ];
    if (conflict.isNotEmpty) {
      return '${conflict.join('、')} 既做了整体替换又选了音色。'
          '整体替换会用候选素材自己的口播，换音色会用合成的口播，'
          '同一段只能要一个——请取消其中一项';
    }

    // 有配乐却没有分离出来的人声轨：新配乐只能叠在原混音上，原片自带的
    // 背景音还在，成片里两首曲子一起响。
    // **空白任务豁免**：它没有原片，声音全部来自素材、由 separateMaterial
    // 逐条分离——按「必须有原片人声轨」拦它等于配了乐就永远导不出
    // （预览侧一直是豁免的，两边规则要一致）
    if (sourcePath != null &&
        bgm.segments.isNotEmpty &&
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
    required String? sourcePath,
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
    ExportSpec? spec,
    List<AsrSentence> subtitleSentences = const [],
    ExportProgress? onProgress,
  }) async {
    final combos = ExportPlanner.enumerate(
      units: units,
      replacements: replacements,
      limit: limit,
    );
    return exportCombinations(
      combos: combos,
      sourcePath: sourcePath,
      units: units,
      replacements: replacements,
      outputDir: outputDir,
      bgm: bgm,
      voiceAudio: voiceAudio,
      voices: voices,
      vocalsPath: vocalsPath,
      spec: spec,
      subtitleSentences: subtitleSentences,
      onProgress: onProgress,
    );
  }

  /// 导出**已经定好的那几条组合**，不再做笛卡尔积。
  ///
  /// [exportAll] 是「人挑候选 → 笛卡尔积」那条路；这条是给 Agent 用的——
  /// 它提交的是一份完整方案列表，每条都是整体设计过的（见 spec 第四节：
  /// 笛卡尔积隐含「任意搭配都成立」，与「挑的时候要看前后是否顺畅」冲突）。
  ///
  /// [replacements] 仍要传：交付前的检查（换过音色的单元有没有生成配音、
  /// 被配乐盖住的段落有没有纯人声）是按它判的。
  Future<List<ExportOutcome>> exportCombinations({
    required List<ExportCombination> combos,
    required String? sourcePath,
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    required Directory outputDir,
    BgmPlan bgm = BgmPlan.empty,
    Map<int, String> voiceAudio = const {},
    VoicePlan voices = VoicePlan.empty,
    String? vocalsPath,
    ExportSpec? spec,

    /// 句级转写（任务的 asrSentences）。镜头替换换掉画面后，原片烧在像素
    /// 里的台词字幕跟着没了——用它在替换切片上重渲同一句台词；空表示没有
    /// 转写（老任务/空白任务），切片照渲、不带字幕
    List<AsrSentence> subtitleSentences = const [],
    ExportProgress? onProgress,
  }) async {
    if (combos.isEmpty) return const [];

    workDir.createSync(recursive: true);
    outputDir.createSync(recursive: true);
    final total = combos.length;

    // 同一个候选会在预取和渲染两处用到，也会在多条组合里重复出现——
    // 记的是 **Future**：并行渲染时两个段同时要同一条素材，也只下载一次
    final renderSpec = spec ?? defaultSpec;
    final fetched = <int, Future<String>>{};
    Future<String> material(int id) => fetched[id] ??= fetchMaterial(id);
    // 同一条素材的时长探测同理：一次 ffprobe，处处复用
    final probed = <String, Future<int?>>{};
    Future<int?> probeOnce(String path) => probed[path] ??= _probeQuietly(path);

    // 出片前先把「会静默做错」的几件事拦掉。
    //
    // **预览可以降级，成片不行**：预览时人还在编辑、听得出来；成片少一段
    // 垫乐、少一句换过的配音、或者新旧背景叠在一起，交付出去没人会发现。
    // 宁可这一次导不出来，也不能给一条看起来正常、其实是错的片子。
    // 变速倍率**不设上限**：预览渲染的就是真实倍率的切片，用户在预览里
    // 看到 2.9× 什么样、导出来就是什么样——他看过并接受了，就不该拦。
    // 原来这里有一道 0.8×~2.0× 的闸，是在替用户做审美判断，已拆掉
    final blocker =
        _blankBlocker(combos, sourcePath) ??
        _deliveryBlocker(
          bgm: bgm,
          vocalsPath: vocalsPath,
          voices: voices,
          voiceAudio: voiceAudio,
          sourcePath: sourcePath,
          replacements: replacements,
        );
    if (blocker != null) {
      AppLog.warn('导出前置检查未通过：$blocker');
      return [
        for (final c in combos) ExportOutcome(index: c.index, failure: blocker),
      ];
    }

    onProgress?.call(0, total, '准备声音');
    // 整体替换的那些单元：把候选下到本地并读出真实时长。
    // 声音要取自它、后面所有单元的位置也要按它的新长度重算
    final Map<int, Map<int, ({String path, int ms})>> wholeByCombo = {};
    try {
      for (var i = 0; i < combos.length; i++) {
        final per = <int, ({String path, int ms})>{};
        for (final segment in combos[i].segments) {
          final id = segment.candidateId;
          // shotIndex == null 才是整体替换（镜头替换有 shotIndex）
          if (id == null || segment.shotIndex != null) continue;
          final path = await material(id);
          final ms = await _probeQuietly(path) ?? segment.durationMs;
          per[segment.unitIndex] = (path: path, ms: ms);
        }
        wholeByCombo[i] = per;
      }
    } catch (e) {
      AppLog.warn('导出：整体替换的素材准备失败：$e');
      return [
        for (final c in combos)
          ExportOutcome(index: c.index, failure: '整体替换的素材取不到：$e'),
      ];
    }

    // 配乐每段只有一首时所有变体的声音一模一样，合一次就够；有备选（轮流用）
    // 或整体替换（各条变体的候选不同、时长也不同）就得逐条合
    final perVariant =
        bgm.segments.any((s) => s.materials.length > 1) ||
        wholeByCombo.values.any((m) => m.isNotEmpty);

    /// 合第 [i] 条变体的声音。配乐没铺上就抛——成片少一段垫乐是静默的错。
    /// 抛出来的原因统一带「声音合成失败」前缀：调用方在两处接它（共用那条
    /// 在循环外、逐条那条在循环里），错误文案不该因为走了哪条路而不同
    Future<String> buildAudio(int i) async {
      final AudioTrack track;
      try {
        track =
            await AudioTrackBuilder(
              run: run,
              // 逐条合时各用各的目录，否则中间产物互相覆盖
              workDir: perVariant
                  ? Directory(p.join(workDir.path, 'audio_v$i'))
                  : workDir,
              resolveBgm: resolveBgm,
              separateMaterial: separateMaterial,
              exportFps: renderSpec.fps.toDouble(),
            ).build(
              sourcePath: sourcePath,
              units: units,
              vocalsPath: vocalsPath,
              bgm: bgm,
              voiceAudio: voiceAudio,
              variantIndex: i,
              wholeAudio: {
                for (final e in (wholeByCombo[i] ?? const {}).entries)
                  e.key: e.value.path,
              },
              wholeDurations: {
                for (final e in (wholeByCombo[i] ?? const {}).entries)
                  e.key: e.value.ms,
              },
            );
      } catch (e) {
        throw Exception('声音合成失败：$e');
      }
      if (track.bgmWarnings.isNotEmpty) {
        throw Exception('声音合成失败：配乐没能铺上——${track.bgmWarnings.join('；')}');
      }
      return track.path;
    }

    // 共用那条要在这里就合出来：它挂了**每一条**都成不了。
    // 逐条合的放到下面各自的 try 里——一条的声音挂了不该拖累其余。
    String? sharedAudio;
    if (!perVariant) {
      try {
        sharedAudio = await buildAudio(0);
      } catch (e) {
        AppLog.warn('导出：$e');
        // 共用的那条声音挂了，每一条都成不了——如实给同一个原因
        return [
          for (final c in combos) ExportOutcome(index: c.index, failure: '$e'),
        ];
      }
    }

    final clips = <String, Future<String>>{}; // 段落指纹 → 渲染中/已渲染的切片
    final out = <ExportOutcome>[];
    for (final combo in combos) {
      onProgress?.call(out.length, total, '第 ${combo.index} 条');
      try {
        final path = await _composeOne(
          combo: combo,
          sourcePath: sourcePath,
          material: material,
          probe: probeOnce,
          audio: sharedAudio ?? await buildAudio(out.length),
          outputDir: outputDir,
          clips: clips,
          renderSpec: renderSpec,
          subtitleSentences: subtitleSentences,
        );
        out.add(ExportOutcome(index: combo.index, path: path));
      } catch (e) {
        AppLog.warn('导出：第 ${combo.index} 条失败：$e');
        out.add(ExportOutcome(index: combo.index, failure: '$e'));
      }
    }
    onProgress?.call(total, total, '完成');
    // 工作目录**留着**：切片和音轨都按内容指纹命名——改一个候选重导，
    // 没变的段落直接命中磁盘、一次 ffmpeg 都不跑（「算过一次的东西要落地
    // 复用，改动了才重算」）。它按任务归属在产物清单里：删任务时一并清、
    // 设置页可统计可清理，不会变成孤儿
    return List.unmodifiable(out);
  }

  /// 拼一条成片：逐段渲染画面 → concat → 与共用的声音合成
  Future<String> _composeOne({
    required ExportCombination combo,
    required String? sourcePath,
    required String audio,
    required Directory outputDir,
    required Map<String, Future<String>> clips,
    required Future<String> Function(int id) material,
    required Future<int?> Function(String path) probe,
    required ExportSpec renderSpec,
    required List<AsrSentence> subtitleSentences,
  }) async {
    // 段落渲染并行（窗口 3）：一条成片几十段逐段串行是导出慢的主因之一。
    // 窗口不开大——每个 ffmpeg 自己就吃多核，开太多只会互相抢
    final parts = List<String?>.filled(combo.segments.length, null);
    for (var i = 0; i < combo.segments.length; i += 3) {
      final batch = [
        for (var j = i; j < combo.segments.length && j < i + 3; j++)
          _renderSegment(
            combo.segments[j],
            sourcePath,
            clips,
            material,
            probe,
            renderSpec,
            subtitleSentences,
          ).then((path) => parts[j] = path),
      ];
      await Future.wait(batch);
    }

    final listFile = File(p.join(workDir.path, 'concat_${combo.index}.txt'))
      ..writeAsStringSync(ExportCommands.concatList(parts.cast<String>()));
    final silent = p.join(workDir.path, 'video_${combo.index}.mp4');
    await _ffmpeg(
      ExportCommands.concat(listFile: listFile.path, out: silent),
      '拼接画面',
    );

    // 扩展名跟着格式走。选了 mov 却导出 .mp4，双击能开但拖进剪辑软件
    // 会被当成另一种东西
    final out = p.join(
      outputDir.path,
      '变体${combo.index}.${renderSpec.fileExtension}',
    );
    await _ffmpeg(
      ExportCommands.mux(video: silent, audio: audio, out: out),
      '画面与声音合成',
    );
    return out;
  }

  /// 空白任务里还没挑素材的分子。
  ///
  /// 没有原片垫底，这种段落**没有任何东西可以放**。不能拿黑场顶上，也不能
  /// 悄悄跳过——那都属于「影响最终成片的东西出了错却不说」。一次把所有空着
  /// 的点名，免得用户填一个导一次。
  static String? _blankBlocker(
    List<ExportCombination> combos,
    String? sourcePath,
  ) {
    if (sourcePath != null) return null;
    final empty = <int>{};
    for (final combo in combos) {
      for (final segment in combo.segments) {
        if (segment.isOriginal) empty.add(segment.unitIndex);
      }
    }
    if (empty.isEmpty) return null;
    final names = (empty.toList()..sort()).map((i) => 'U${i + 1}').join('、');
    return '$names 还没有挑素材。删掉这些分子，或者把它们挑满，再导出';
  }

  /// 渲染一段画面。同一段在多条组合里会重复出现，按指纹缓存，只做一遍。
  Future<String> _renderSegment(
    ExportSegment segment,
    String? sourcePath,
    Map<String, Future<String>> clips,
    Future<String> Function(int id) material,
    Future<int?> Function(String path) probe,
    ExportSpec renderSpec,
    List<AsrSentence> subtitleSentences,
  ) async {
    // 规格进指纹：同一段在 1080 和 720 下是两份不同的产物，
    // 不区分的话第二次导出会直接命中第一次的缓存，用户拿到的还是旧规格。
    // 镜头替换的字幕（内容 + 样式）同理——字幕在指纹里，改了就重渲
    final subtitleLines = segment.shotIndex == null
        ? const <SubtitleLine>[]
        : subtitleLinesInSlot(
            sentences: subtitleSentences,
            slotStartMs: segment.startMs,
            slotEndMs: segment.endMs,
          );
    final subKey = subtitleLines.isEmpty
        ? ''
        : '_sub${[for (final l in subtitleLines) '${l.startMs}-${l.endMs}:${l.text}'].join('|').hashCode}'
              '_${subtitleStyle.fingerprint.hashCode}';
    final key =
        '${segment.startMs}_${segment.endMs}_${segment.candidateId}'
        '_${renderSpec.fingerprint}$subKey';
    // Future 记忆化：并行渲染时同一段只渲一次，后来的等同一个结果
    return clips[key] ??= () async {
      final out = p.join(workDir.path, 'clip_$key.mp4');
      // 增量重导：上次导出留下的切片按指纹直接复用——改一个候选重导，
      // 没变的段落一次 ffmpeg 都不跑
      if (File(out).existsSync() && File(out).lengthSync() > 0) return out;
      if (segment.isOriginal) {
        // 空白任务没有原片。走到这儿说明有一段没挑素材而前置检查漏了——
        // 让它掉进 ffmpeg 只会得到一句「No such file」，指不出是哪一段
        if (sourcePath == null) {
          throw StateError(
            'U${segment.unitIndex + 1} 这一段要用原片，但这条任务没有原片。'
            '请给它挑一条素材，或者删掉这个分子',
          );
        }
        await _ffmpeg(
          ExportCommands.trimOriginalVideo(
            source: sourcePath,
            startMs: segment.startMs,
            endMs: segment.endMs,
            out: out,
            spec: renderSpec,
          ),
          'U${segment.unitIndex + 1} 的原片画面',
        );
      } else {
        final path = await material(segment.candidateId!);
        if (segment.shotIndex == null) {
          // **整体替换：原样接上**，不加速不放慢不裁不补，时长随候选
          await _ffmpeg(
            ExportCommands.wholeReplacementVideo(
              spec: renderSpec,
              input: path,
              out: out,
            ),
            'U${segment.unitIndex + 1} 的替换画面',
          );
        } else {
          // 镜头替换：变速对齐到原坑位（口播不动，画面必须严丝合缝），
          // 并把这段台词的字幕重渲上去——原片的字幕烧在被换掉的画面里
          final overlays = subtitleLines.isEmpty
              ? const <SubtitleOverlayImage>[]
              : await rasterizer.rasterize(
                  lines: subtitleLines,
                  // 与切片同一个输出分辨率——跟导出规格，不吃成片标准死值
                  width: renderSpec.width,
                  height: renderSpec.height,
                  style: subtitleStyle,
                  outDir: workDir,
                );
          await _ffmpeg(
            ExportCommands.fitCandidateVideo(
              input: path,
              durationMs: segment.durationMs,
              candidateDurationMs: await probe(path),
              out: out,
              subtitleOverlays: overlays,
              // 规格必须贯穿：这段与原片段进同一条 concat 清单
              spec: renderSpec,
            ),
            'U${segment.unitIndex + 1} 的替换画面',
          );
        }
      }
      return out;
    }();
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
      final tail = stderr.length > 3
          ? stderr.sublist(stderr.length - 3)
          : stderr;
      throw Exception('$what 失败：${tail.join(' / ')}');
    }
  }
}
