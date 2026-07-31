/// 分析管线的阶段。顺序即执行顺序，界面按 index 显示「第 n 步 / 共 m 步」。
enum AnalysisStage {
  extractingAudio,
  detectingScenes,
  transcribing,
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
  AnalysisStage.extractingAudio: '正在分离音频',
  AnalysisStage.detectingScenes: '正在识别画面切换',
  AnalysisStage.transcribing: '正在识别台词',
  AnalysisStage.splitting: '正在按语义切分台词',
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
