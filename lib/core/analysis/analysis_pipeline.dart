import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../ai/taggers.dart';
import '../ffmpeg/thumbnail_service.dart';
import '../ai/ai_usage.dart';
import '../ai/ai_usage_scope.dart';
import '../log/app_log.dart';
import 'source_print.dart';
import 'prepared_cache.dart';
import '../audio/vocal_separator.dart';
import '../models/renew_task.dart';
import 'tag_merge.dart';
import '../models/semantic_unit.dart';
import '../storage/task_repository.dart';
import 'analysis_progress.dart';
import 'boundary_trace_index.dart';
import 'batch_frame_extractor.dart';
import 'audio_extractor.dart';
import 'providers.dart';
import 'scene_detector.dart';
import 'segmentation_builder.dart';
import 'shot_boundary_finder.dart';
import 'silence_detector.dart';
import 'tag_vocabulary.dart';
import 'tagging_service.dart';

/// 任务音频 PCM 的中间产物路径（分析管线与时间线波形共用同一份）。
///
/// 两处提取参数完全相同（16kHz 单声道 s16le），分开存会让同一份音频被写两
/// 遍：一条 5 分钟素材约 20MB，白白翻倍。共用后时间线可直接命中管线的产物，
/// 连第二次 ffmpeg 都省掉。
/// 时间线波形缓存：算好的包络（几 KB），不是 PCM。
/// 命名带 `<taskId>_` 前缀，删任务与孤儿清扫自动覆盖到它（见 TaskArtifacts）
String timelineWavePath(Directory workDir, String taskId) =>
    p.join(workDir.path, '${taskId}_wave.json');

String analysisPcmPath(Directory workDir, String taskId) =>
    p.join(workDir.path, '$taskId.pcm');

/// 送去做视觉理解的帧高度。
///
/// 多帧时分辨率是 token 消耗的主因，而判断「画面是什么」不需要原始 1080p；
/// 竖屏 9:16 下 512 高约合 288 宽，主体与场景仍然清晰可辨。
const int understandingFrameHeight = 512;

/// 分析管线编排：PCM 提取 → 静音谷 → 场景检测 → ASR → 语义切分 → 吸附构树 → 打标 → 落库
/// 分析前半程的产物。**必须能落盘**：PCM 转完就删，静音谷算不回来；
/// 镜头切点重算要几十秒。CLI 把它存起来，等调用方回填切分之后接着跑。
class PreparedAnalysis {
  final List<AsrSentence> sentences;
  final List<int> valleys;
  final List<int> shotBounds;
  final String? vocalsPath;
  final String? backgroundPath;

  const PreparedAnalysis({
    required this.sentences,
    required this.valleys,
    required this.shotBounds,
    this.vocalsPath,
    this.backgroundPath,
  });

  /// 换上**这条任务自己的**人声轨。
  ///
  /// 人声轨归任务所有（落在 `stems/<taskId>/`），任务一删就跟着走；而这份
  /// 产物按源文件内容缓存、能活得比任何一条任务都久。两者生命周期不同，
  /// 所以复用缓存里的切分时必须重新配一份自己的，绝不能沿用别人那条路径
  PreparedAnalysis withStems(SeparatedAudio? stems) => PreparedAnalysis(
        sentences: sentences,
        valleys: valleys,
        shotBounds: shotBounds,
        vocalsPath: stems?.vocalsPath,
        backgroundPath: stems?.backgroundPath,
      );

  /// 抹掉人声轨路径的副本——进缓存前必须过这一道，理由见 [PreparedCache.save]
  PreparedAnalysis withoutStems() => withStems(null);

  Map<String, dynamic> toJson() => {
        'sentences': [for (final s in sentences) s.toJson()],
        'valleys': valleys,
        'shotBounds': shotBounds,
        'vocalsPath': vocalsPath,
        'backgroundPath': backgroundPath,
      };

  static PreparedAnalysis? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final sentences = raw['sentences'];
    if (sentences is! List) return null;
    return PreparedAnalysis(
      sentences: [
        for (final s in sentences)
          if (s is Map<String, dynamic>) AsrSentence.fromJson(s),
      ],
      valleys: [for (final v in (raw['valleys'] as List? ?? [])) v as int],
      shotBounds: [
        for (final b in (raw['shotBounds'] as List? ?? [])) b as int,
      ],
      vocalsPath: raw['vocalsPath'] as String?,
      backgroundPath: raw['backgroundPath'] as String?,
    );
  }
}

class AnalysisPipeline {
  final AudioExtractor audio;
  final SilenceDetector silence;
  final SceneDetector scenes;

  /// 视觉镜头切点求解（双判据 + 灰区画面复核）。null 时回退到 [scenes] 的
  /// 单一 scene 阈值——旧口径，只抓得住最剧烈的硬切，见
  /// docs/plans/2026-08-01-镜头切分优化.md
  final ShotBoundaryFinder? shotBoundaries;
  final AsrProvider asr;
  final SemanticSplitter splitter;
  final SegmentationBuilder builder;
  final TaskRepository repository;
  final Directory workDir;
  final int sampleRate;
  final DateTime Function() clock;
  final UnitTagger? unitTagger;
  final ShotTagger? shotTagger;
  final ThumbnailService? thumbnails;

  /// 全片打标时一次抽完所有代表帧；为空则一律逐帧抽
  final BatchFrameExtractor? batchFrames;

  /// 受控词表的来源。词表是**按任务**解析的（取决于该任务在新建向导里选的
  /// 两个标签组），所以这里注入的是「按组 id 查词表」的能力，而不是一份写死
  /// 的词表——后者等于所有任务共用一份，受控词表也就名存实亡。
  final TagVocabularySource? vocabulary;

  /// 口播/背景音分离。为 null 表示这台机器上没装分离工具——照常分析，
  /// 只是「替换配乐」时没有干净的人声轨可用（那一步会自己说明原因）。
  final VocalSeparator? separator;

  AnalysisPipeline({
    required this.audio,
    this.separator,
    required this.silence,
    required this.scenes,
    this.shotBoundaries,
    required this.asr,
    required this.splitter,
    required this.builder,
    required this.repository,
    required this.workDir,
    this.sampleRate = 16000,
    DateTime Function()? clock,
    this.unitTagger,
    this.shotTagger,
    this.thumbnails,
    this.batchFrames,
    this.vocabulary,
  })  : clock = clock ?? DateTime.now,
        tagging = TaggingService(
          unitTagger: unitTagger,
          shotTagger: shotTagger,
          thumbnails: thumbnails,
          batchFrames: batchFrames,
          vocabulary: vocabulary,
          workDir: workDir,
          clock: clock ?? DateTime.now,
        );

  /// 两层打标已经拆出去（见 [TaggingService]）：打标不只发生在首次分析，
  /// 用户改完切分后还能在工作台里要求重打其中几个单元，那时整条管线
  /// （抽音频、ASR、语义切分）都不该再跑一遍。对外可见就是为了那条路径。
  final TaggingService tagging;

  /// 每一步"等了多久"。
  ///
  /// **并行之后这不再等于该步骤的实际耗时**：三条支线同时跑，先 await 的那条
  /// 把时间都记在自己头上，后 await 的往往已经做完、只记很小的数。这个口径
  /// 反而更有用——它衡量的是"这一步让人多等了多久"。
  ///
  /// 每一步真正花了多久。
  ///
  /// **为什么要留在代码里**：这条链路有八步、跨本地与云端，"到底慢在哪儿"
  /// 只能靠实测。此前靠读注释推断过一次，注释早已过时——把 ffmpeg 解码
  /// 说成瓶颈，实际瓶颈是云端并发。凭猜测优化等于白干。
  final _stageMs = <AnalysisStage, int>{};
  Stopwatch? _stageWatch;
  AnalysisStage? _currentStage;

  /// 各阶段耗时（毫秒）。分析结束后可读，供日志与排查用。
  Map<AnalysisStage, int> get stageDurationsMs => Map.unmodifiable(_stageMs);

  void _closeStage() {
    final stage = _currentStage;
    final watch = _stageWatch;
    if (stage != null && watch != null) {
      _stageMs[stage] = (_stageMs[stage] ?? 0) + watch.elapsedMilliseconds;
    }
  }

  /// 上报一步进度。
  ///
  /// 回调抛异常只记日志：进度只是「说一声」，因为没人听就把整条分析废掉，
  /// 等于让十几分钟的计算白跑。
  /// 删不掉不算错误：留着最多占点地方，为它中断分析才是本末倒置
  static Future<void> _discardPcm(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      AppLog.warn('清理 ASR 中转 PCM 失败 $path：$e');
    }
  }

  void _report(AnalysisProgressSink? sink, AnalysisStage stage,
      {int? done, int? total}) {
    // 同一阶段的多次进度上报（打标的 n/m）不重新计时，只在换阶段时结算
    if (stage != _currentStage) {
      _closeStage();
      _currentStage = stage;
      _stageWatch = Stopwatch()..start();
    }
    if (sink == null) return;
    try {
      sink(AnalysisProgress(stage: stage, done: done, total: total));
    } catch (e) {
      AppLog.warn('分析进度回调抛异常（已忽略）：$e');
    }
  }

  /// [onProgress] 逐次传入而不是挂在实例上：管线是全应用共享的单例，
  /// 挂在实例上会让所有任务的进度都涌向同一个回调，还分不清是谁的。
  ///
  /// [onUnitsReady] 在**切分落库、打标开始之前**回调一次：那一刻任务已经能
  /// 打开干活了（看切分、拖边界、听原片都不需要标签）。上层据此把任务从
  /// 「分析中」放出来，剩下的打标在后台补。实测切分好只要 26 秒，而打标要
  /// 七十多秒——让人干等三倍时间没道理。
  /// 分析一条任务，并把这一轮花掉的 AI 用量记到它头上。
  ///
  /// 记账包住整个分析（见 [AiUsageScope]）：语义切分、切点复核、两层打标的
  /// 调用都埋在下面几层里，且几十个并发同时在跑，只有 Zone 拦得住全部。
  /// 分析失败时也要结账——花掉的 token 不会因为失败退回来。
  Future<RenewTask> analyze(RenewTask task,
      {AnalysisProgressSink? onProgress,
      void Function(RenewTask ready)? onUnitsReady}) async {
    RenewTask? result;
    final usage = await AiUsageScope.collect(
      () async {
        result = await _analyze(task,
            onProgress: onProgress, onUnitsReady: onUnitsReady);
      },
      onPartial: (partial) => unawaited(_billFailed(task.id, partial)),
    );
    return _bill(result!, usage);
  }

  /// 把用量并进任务并落库
  Future<RenewTask> _bill(RenewTask task, AiUsage usage) async {
    if (usage.calls == 0) return task;
    final billed = task.copyWith(
        aiUsage: task.aiUsage.merge(usage), updatedAt: clock());
    await repository.save(billed);
    return billed;
  }

  /// 分析失败时结账：花掉的 token 不会退回来，账要照记。
  ///
  /// **尽力而为，绝不抛**：这条路上真正要交给上层的是分析失败的原因，
  /// 结账再抛一个错只会把它盖掉——实测就盖掉过一次 StateError。
  Future<void> _billFailed(String id, AiUsage usage) async {
    if (usage.calls == 0) return;
    try {
      final current = await repository.findById(id);
      if (current == null) return;
      await repository.save(current.copyWith(
          aiUsage: current.aiUsage.merge(usage), updatedAt: clock()));
    } catch (e) {
      AppLog.warn('任务 $id 分析失败后的用量结账没写成（不影响报错）：$e');
    }
  }

  /// 分析的**前半程**：抽音频 → 分离 / 镜头切点 / ASR（三条并行）。
  ///
  /// 抽出来是为了让 CLI 能在这里停一下，把语义切分交给调用方去做
  /// （见 spec 第三节）。这几步都不可外包：ASR 的时间戳没法验证，
  /// 其余是本地计算。
  ///
  /// 返回的东西必须**全部落盘**才能续跑——PCM 转完就删了，静音谷算不回来；
  /// 镜头切点重算要几十秒。
  Future<PreparedAnalysis> prepare(RenewTask task,
      {AnalysisProgressSink? onProgress}) async {
    // 空白任务没有原片，整条分析都无从谈起。挡在最外层并说清楚——
    // 让它往下走，最后是 ffmpeg 报一句「No such file」，谁也看不懂
    final sourcePath = task.sourcePath;
    if (sourcePath == null) {
      throw StateError('任务 ${task.id} 是一条空白任务，没有原片可分析。'
          '分子和标签在 app 里手动填');
    }
    final info = task.videoInfo;
    if (info == null) {
      throw StateError('任务 ${task.id} 缺少视频元信息，无法分析');
    }
    // **同一条片子重新导入就复用上次的切分**：语义切分是 LLM 干的、
    // 有随机性——真机上同一个文件导三次切出 3/4/5 个单元，于是方案文件
    // 不能跨任务复用（`unit 2 shot 3` 在新任务里指向别的画面），
    // 「1:1 复刻」也打了折扣。顺带省掉一次 ASR + LLM（真金白银）
    final sourcePrint = sourcePrintOf(sourcePath);
    final cache = PreparedCache(workDir.parent);
    if (cache.load(sourcePrint) case final hit?) {
      AppLog.info('这条片子分析过了，直接用上次的切分（$sourcePrint）');
      // **说清是复用不是重跑**：报成 building 的话，后面真的 building
      // 时会再报一次，人看着像倒退了
      _report(onProgress, AnalysisStage.reusingPrepared);
      // 切分能复用，人声轨不能——它归任务所有，别人删任务时会被一起清掉。
      // 所以这里仍要为当前这条任务分离一份自己的（同一条任务重进不会重跑，
      // [VocalSeparator.separate] 认自己名下已有的产物）。这一步十几秒，
      // 必须报出来，不能让进度条挂着不动
      _report(onProgress, AnalysisStage.separatingVocals);
      return hit.withStems(await _separate(task, sourcePath));
    }

    await workDir.create(recursive: true);
    final pcmPath = analysisPcmPath(workDir, task.id);

    _report(onProgress, AnalysisStage.extractingAudio);
    final samples = await audio.extractSamples(
        videoPath: sourcePath,
        outPcmPath: pcmPath,
        sampleRate: sampleRate);
    final valleys = silence.detectValleyCenters(samples, sampleRate);

    _report(onProgress, AnalysisStage.separatingVocals);
    final stemsFuture = _separate(task, sourcePath);
    final boundsFuture = _detectShotBoundaries(task, sourcePath, info.fps);
    final sentencesFuture = asr.transcribe(pcmPath);

    _report(onProgress, AnalysisStage.transcribing);
    final sentences = await sentencesFuture;
    unawaited(_discardPcm(pcmPath));

    _report(onProgress, AnalysisStage.detectingScenes);
    final shotBounds = await boundsFuture;
    final stems = await stemsFuture;

    final prepared = PreparedAnalysis(
      sentences: sentences,
      valleys: valleys,
      shotBounds: shotBounds,
      vocalsPath: stems?.vocalsPath,
      backgroundPath: stems?.backgroundPath,
    );
    // 存下来：下次导入同一条片子直接用，结构才稳得住
    cache.save(sourcePrint, prepared);
    return prepared;
  }

  /// 用切分草稿组装成单元。**纯本地**，不碰云端。
  ///
  /// [drafts] 可以来自内置的语义切分，也可以来自调用方回填——两条路走到
  /// 这里之后完全一样。
  List<SemanticUnit> assemble({
    required RenewTask task,
    required List<UnitDraft> drafts,
    required PreparedAnalysis prepared,
  }) {
    final info = task.videoInfo!;
    return _withBoundaryTrace(fps: info.fps, builder.build(
      drafts: drafts,
      shotBoundaryMs: prepared.shotBounds,
      silenceValleyMs: prepared.valleys,
      videoDurationMs: info.duration.inMilliseconds,
      fps: info.fps,
    ));
  }

  Future<RenewTask> _analyze(RenewTask task,
      {AnalysisProgressSink? onProgress,
      void Function(RenewTask ready)? onUnitsReady}) async {
    final startedAt = clock();
    // 空白任务没有原片，整条分析都无从谈起（同 prepare 的守卫）
    final sourcePath = task.sourcePath;
    if (sourcePath == null) {
      throw StateError('任务 ${task.id} 是一条空白任务，没有原片可分析。'
          '分子和标签在 app 里手动填');
    }
    final info = task.videoInfo;
    if (info == null) {
      throw StateError('任务 ${task.id} 缺少视频元信息，无法分析');
    }
    // **前半程走同一个 prepare**：以前这里自己抄了一遍（抽音频、分离、
    // 镜头切点、ASR），于是「按源文件复用切分」那个缓存只覆盖了外包那条路，
    // 内置全流程照样每次重跑——真机上同一条片子导两次还是切出不同的边界。
    // 同一件事两处实现，改一处漏一处
    final prepared = await prepare(task, onProgress: onProgress);
    final sentences = prepared.sentences;
    final valleys = prepared.valleys;
    final shotBounds = prepared.shotBounds;

    // **语义切分也要缓存**：ASR 句子是稳定的，而按语义分组是 LLM 干的——
    // 真机上同一条片子切出 3/4/5 个单元，随机性全在这一步。
    // 不缓存它的话，之前挑好的素材方案在重导后照样对不上号
    _report(onProgress, AnalysisStage.splitting);
    final print2 = sourcePrintOf(sourcePath);
    final cache2 = PreparedCache(workDir.parent);
    var drafts = cache2.loadDrafts(print2);
    if (drafts == null) {
      drafts = await splitter.split(sentences);
      cache2.saveDrafts(print2, drafts);
    } else {
      AppLog.info('这条片子切过了，直接用上次的语义切分（$print2）');
    }

    _report(onProgress, AnalysisStage.building);
    final units = builder.build(
      drafts: drafts,
      shotBoundaryMs: shotBounds,
      silenceValleyMs: valleys,
      videoDurationMs: info.duration.inMilliseconds,
      fps: info.fps,
    );

    // 切分好就先落库、先放人进去干活——打标（实测占总时长七成）不该挡着。
    // 用户进工作台第一件事是看切分对不对、拖边界，那些都不需要标签。
    final ready = task.copyWith(
      units: _withBoundaryTrace(units, fps: info.fps),
      status: RenewTaskStatus.ready,
      updatedAt: clock(),
      asrSentences: sentences,
      vocalsPath: prepared.vocalsPath,
      backgroundPath: prepared.backgroundPath,
      // 人真正等到这一刻就能进去干活了；只记第一次
      firstReadyMs: task.firstReadyMs ??
          clock().difference(startedAt).inMilliseconds,
    );
    await repository.save(ready);
    onUnitsReady?.call(ready);
    AppLog.info('切分已就绪（${units.length} 个单元），打标转入后台');

    final taggedUnits =
        await tagging.tag(ready, ready.units!, onProgress: onProgress);

    _closeStage();
    _currentStage = null;
    AppLog.info('分析耗时：${[
      for (final e in _stageMs.entries)
        '${e.key.name} ${(e.value / 1000).toStringAsFixed(1)}s'
    ].join('、')}；合计 '
        '${(_stageMs.values.fold<int>(0, (a, b) => a + b) / 1000).toStringAsFixed(1)}s');

    // **不能拿 ready 直接写回去**：打标占总时长七成，这七成里人已经被放进
    // 工作台干活了（上面那句 onUnitsReady 就是干这个的）。他拖过的边界、
    // 改过的台词此刻在盘上，而 ready 是打标开始那一刻的样子——整份写回去
    // 等于把他这几分钟的活悄没声儿地抹掉。
    //
    // 所以重读一次，只把标签合并到**当前**的单元上（边界变过的不认，
    // 见 [mergeTagsInto]）。
    final latest = await repository.findById(ready.id) ?? ready;
    final updated = latest.copyWith(
      units: mergeTagsInto(latest.units ?? const [], taggedUnits),
      updatedAt: clock(),
    );
    await repository.save(updated);
    return updated;
  }

  /// 分离口播与背景音。**失败不中断整条分析**：切分与打标本身仍然有价值，
  /// 为了一条音轨把几分钟的分析结果整个废掉不划算。缺了它只影响「替换配乐」，
  /// 那一步会自己说明原因。
  /// 只重新分离这条任务的人声轨，**不碰切分与打标**。
  ///
  /// 给界面上的「重新分离」用。人声轨归任务所有，丢了（别人删任务时被一起
  /// 清掉）或那次分离失败过，缺的都只是这一份——为它重跑一整轮分析是拿几
  /// 分钟换十几秒。空白任务没有原片、机器上没装工具，都返回 null，
  /// 不许拿空路径去跑 ffmpeg。
  ///
  /// **失败照原样抛出**：这是用户主动点的，他在等一个结果，出了错就得让他
  /// 看见原因。分析途中那次不一样，见 [_separate]
  Future<SeparatedAudio?> separateVocals(RenewTask task) async {
    final sourcePath = task.sourcePath;
    final tool = separator;
    if (sourcePath == null || tool == null) return null;
    return tool.separate(
      audioPath: sourcePath,
      // 各任务各存各的：这份产物归任务所有，别人删任务时不该碰到它
      outputDir: Directory(p.join(workDir.path, 'stems', task.id)),
    );
  }

  /// 分析途中的那次分离。**失败只记一笔就过**——为了一条音轨把几分钟的
  /// 切分与打标废掉不划算，人声轨事后单独补得回来（[separateVocals]）
  Future<SeparatedAudio?> _separate(RenewTask task, String sourcePath) async {
    try {
      return await separateVocals(task);
    } catch (e) {
      AppLog.warn('任务 ${task.id} 的口播/背景音分离失败（不影响其余分析）：$e');
      return null;
    }
  }

  /// 求视觉镜头切点。新链路（双判据 + 画面复核）失败时退回旧的单一阈值
  /// 检测——切分结果本身仍有价值，为了「切得更准」把整条分析废掉不划算。
  Future<List<int>> _detectShotBoundaries(
      RenewTask task, String sourcePath, double fps) async {
    final finder = shotBoundaries;
    if (finder == null) return scenes.detect(sourcePath);
    try {
      return await finder.find(
          videoPath: sourcePath, taskId: task.id, fps: fps);
    } catch (e) {
      AppLog.warn('镜头切点检测失败，退回基础场景检测：$e');
      return scenes.detect(sourcePath);
    }
  }

  /// 把切点判定明细贴到镜头上：每个镜头的**起点**就是那一刀，画面差异分数
  /// 与「直接确认 / 灰区经画面复核保留」都记在这里，事后能回看这一刀的依据。
  List<SemanticUnit> _withBoundaryTrace(List<SemanticUnit> units,
      {double fps = 0}) {
    // **键要先对齐**：切点是原始毫秒，而镜头边界一律吸到帧上
    // （见 `SegmentationBuilder` 的 alignedShotBoundaries）。原来直接拿
    // shot.startMs 去查原始键，绝大多数查不中——「这一刀怎么定出来的」
    // 长期大面积缺失，而缺了不报错，所以一直没人发现
    // （2026-09-15 给底片切分补这一项时量出 7 镜只贴上 2 条，才摸到这里）
    final traces = boundaryTracesByFrame(ShotBoundaryFinder.lastDetails, fps);
    if (traces.isEmpty) return units;
    return List.unmodifiable([
      for (final u in units)
        u.copyWith(shots: [
          for (final s in u.shots)
            if (traces[s.startMs] case final t?)
              s.copyWith(boundaryTrace: t)
            else
              s,
        ]),
    ]);
  }

}
