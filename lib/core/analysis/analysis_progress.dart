/// 分析管线的阶段。顺序即执行顺序，界面按 index 显示「第 n 步 / 共 m 步」。
/// 顺序 = **等待顺序**，不是"开工顺序"。
///
/// 抽完音频之后三条支线是同时开跑的（分离 / 画面切换 / ASR→语义切分），
/// 这里报的是"当前在等谁"。顺序必须与代码里 await 的先后一致——否则进度条
/// 会从「识别台词」倒回「识别画面切换」，用户以为出错重来了。
enum AnalysisStage {
  extractingAudio,
  separatingVocals,
  transcribing,
  // 顺序照着**真实执行**排：镜头切点在前半程（prepare）里出来，
  // 语义切分在它之后。枚举顺序只用来算「第几步」，
  // 排错了进度会倒退，人以为出错重来了
  detectingScenes,
  /// 这条片子分析过了，前半程直接用上次的结果
  reusingPrepared,
  splitting,
  building,
  taggingUnits,
  taggingShots,
}

/// 阶段文案：说「正在做什么」，不说「用什么在做」。
///
/// 用户等的是自己的素材处理完，不是一份管线日志——PCM / ASR / ffmpeg
/// 这些词出现在进度条上只会制造困惑。
const _labels = <AnalysisStage, String>{
  AnalysisStage.extractingAudio: '正在提取音频',
  // 这三条是并行的，文案上不必强调，用户只关心"在做什么"
  AnalysisStage.separatingVocals: '正在分离口播与背景音',
  AnalysisStage.detectingScenes: '正在识别画面切换',
  AnalysisStage.transcribing: '正在识别台词',
  AnalysisStage.splitting: '正在按语义切分台词',
  AnalysisStage.reusingPrepared: '这条片子分析过了，直接用上次的切分',
  AnalysisStage.building: '正在生成切分结构',
  AnalysisStage.taggingUnits: '正在为台词语义单元打标签',
  AnalysisStage.taggingShots: '正在为视觉镜头打标签',
};

/// 分析进度快照（不可变）。
///
/// [done] / [total] 只在**真的有子项计数**的阶段给出（打标）。其余阶段一律
/// 留 null：编一个「0 / 0」或让进度条停在 0%，看起来就是卡死了。
class AnalysisProgress {
  final AnalysisStage stage;
  final int? done;
  final int? total;

  const AnalysisProgress({required this.stage, this.done, this.total});

  static int get stageCount => AnalysisStage.values.length;

  /// 第几步（从 1 开始，直接用于「第 3 步 / 共 7 步」）
  int get stageNumber => stage.index + 1;

  String get label => _labels[stage]!;

  /// 「12 / 32」；没有计数时为 null
  String? get detail {
    final d = done;
    final t = total;
    if (d == null || t == null || t <= 0) return null;
    return '$d / $t';
  }

  /// 确定态进度条的比例；没有计数时为 null（界面应显示不确定态）
  double? get fraction {
    final d = done;
    final t = total;
    if (d == null || t == null || t <= 0) return null;
    return (d / t).clamp(0.0, 1.0);
  }

  /// 任务卡上只有一行的位置用这个
  String get summary {
    final d = detail;
    return d == null ? label : '$label $d';
  }

  AnalysisProgress copyWith({int? done, int? total}) => AnalysisProgress(
        stage: stage,
        done: done ?? this.done,
        total: total ?? this.total,
      );

  @override
  bool operator ==(Object other) =>
      other is AnalysisProgress &&
      other.stage == stage &&
      other.done == done &&
      other.total == total;

  @override
  int get hashCode => Object.hash(stage, done, total);

  @override
  String toString() => 'AnalysisProgress($stage, $done/$total)';
}

/// 进度回调。管线只管报，谁来接、要不要节流由调用方决定。
typedef AnalysisProgressSink = void Function(AnalysisProgress progress);
