import 'dart:io';
import 'package:path/path.dart' as p;
import '../ai/taggers.dart';
import '../ffmpeg/thumbnail_service.dart';
import '../log/app_log.dart';
import '../audio/vocal_separator.dart';
import '../models/renew_task.dart';
import '../models/tag_trace.dart';
import '../models/semantic_unit.dart';
import '../storage/task_repository.dart';
import 'analysis_progress.dart';
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
String analysisPcmPath(Directory workDir, String taskId) =>
    p.join(workDir.path, '$taskId.pcm');

/// 送去做视觉理解的帧高度。
///
/// 多帧时分辨率是 token 消耗的主因，而判断「画面是什么」不需要原始 1080p；
/// 竖屏 9:16 下 512 高约合 288 宽，主体与场景仍然清晰可辨。
const int understandingFrameHeight = 512;

/// 分析管线编排：PCM 提取 → 静音谷 → 场景检测 → ASR → 语义切分 → 吸附构树 → 打标 → 落库
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
    this.vocabulary,
  })  : clock = clock ?? DateTime.now,
        tagging = TaggingService(
          unitTagger: unitTagger,
          shotTagger: shotTagger,
          thumbnails: thumbnails,
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
  Future<RenewTask> analyze(RenewTask task,
      {AnalysisProgressSink? onProgress}) async {
    final info = task.videoInfo;
    if (info == null) {
      throw StateError('任务 ${task.id} 缺少视频元信息，无法分析');
    }
    await workDir.create(recursive: true);
    // 管线始终重新提取（-y 覆盖写）：它是这份 PCM 的权威产出方，
    // 复用可能残留的半截文件会让 ASR 拿到不完整音频
    final pcmPath = analysisPcmPath(workDir, task.id);

    _report(onProgress, AnalysisStage.extractingAudio);
    final samples = await audio.extractSamples(
        videoPath: task.sourcePath,
        outPcmPath: pcmPath,
        sampleRate: sampleRate);
    final valleys = silence.detectValleyCenters(samples, sampleRate);

    // 音频到手之后，三条支线互不依赖，同时跑：
    //   分离（本地 GPU）｜画面切换（本地解码 + 云端复核）｜ASR → 语义切分（云端）
    // 串行跑它们纯属浪费——实测串行 229 秒里，这三条加起来占 120 秒，
    // 而并起来只花最长那条的时间。进度按「最慢的那条」报，不然进度条会跳。
    _report(onProgress, AnalysisStage.separatingVocals);
    final stemsFuture = _separate(task);
    final boundsFuture = _detectShotBoundaries(task, info.fps);
    final sentencesFuture = asr.transcribe(pcmPath);

    _report(onProgress, AnalysisStage.transcribing);
    final sentences = await sentencesFuture;

    _report(onProgress, AnalysisStage.splitting);
    final drafts = await splitter.split(sentences);

    _report(onProgress, AnalysisStage.detectingScenes);
    final shotBounds = await boundsFuture;
    final stems = await stemsFuture;

    _report(onProgress, AnalysisStage.building);
    final units = builder.build(
      drafts: drafts,
      shotBoundaryMs: shotBounds,
      silenceValleyMs: valleys,
      videoDurationMs: info.duration.inMilliseconds,
      fps: info.fps,
    );

    final taggedUnits = await tagging
        .tag(task, _withBoundaryTrace(units), onProgress: onProgress);

    _closeStage();
    _currentStage = null;
    AppLog.info('分析耗时：${[
      for (final e in _stageMs.entries)
        '${e.key.name} ${(e.value / 1000).toStringAsFixed(1)}s'
    ].join('、')}；合计 '
        '${(_stageMs.values.fold<int>(0, (a, b) => a + b) / 1000).toStringAsFixed(1)}s');

    final updated = task.copyWith(
      units: taggedUnits,
      status: RenewTaskStatus.editing,
      updatedAt: clock(),
      asrSentences: sentences,
      vocalsPath: stems?.vocalsPath,
      backgroundPath: stems?.backgroundPath,
    );
    await repository.save(updated);
    return updated;
  }

  /// 分离口播与背景音。**失败不中断整条分析**：切分与打标本身仍然有价值，
  /// 为了一条音轨把几分钟的分析结果整个废掉不划算。缺了它只影响「替换配乐」，
  /// 那一步会自己说明原因。
  Future<SeparatedAudio?> _separate(RenewTask task) async {
    final tool = separator;
    if (tool == null) return null;
    try {
      return await tool.separate(
        audioPath: task.sourcePath,
        outputDir: Directory(p.join(workDir.path, 'stems', task.id)),
      );
    } catch (e) {
      AppLog.warn('任务 ${task.id} 的口播/背景音分离失败（不影响其余分析）：$e');
      return null;
    }
  }

  /// 求视觉镜头切点。新链路（双判据 + 画面复核）失败时退回旧的单一阈值
  /// 检测——切分结果本身仍有价值，为了「切得更准」把整条分析废掉不划算。
  Future<List<int>> _detectShotBoundaries(RenewTask task, double fps) async {
    final finder = shotBoundaries;
    if (finder == null) return scenes.detect(task.sourcePath);
    try {
      return await finder.find(
          videoPath: task.sourcePath, taskId: task.id, fps: fps);
    } catch (e) {
      AppLog.warn('镜头切点检测失败，退回基础场景检测：$e');
      return scenes.detect(task.sourcePath);
    }
  }

  /// 把切点判定明细贴到镜头上：每个镜头的**起点**就是那一刀，画面差异分数
  /// 与「直接确认 / 灰区经画面复核保留」都记在这里，事后能回看这一刀的依据。
  List<SemanticUnit> _withBoundaryTrace(List<SemanticUnit> units) {
    final details = ShotBoundaryFinder.lastDetails;
    if (details.isEmpty) return units;
    BoundaryTrace? traceAt(int ms) {
      final c = details[ms];
      if (c == null) return null;
      return BoundaryTrace(
        sceneScore: c.sceneScore,
        histDistance: c.histDistance,
        decision: c.isConfirmed ? 'confirmed' : 'reviewed',
      );
    }

    return List.unmodifiable([
      for (final u in units)
        u.copyWith(shots: [
          for (final s in u.shots)
            if (traceAt(s.startMs) case final t?) s.copyWith(boundaryTrace: t) else s,
        ]),
    ]);
  }

}
