import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/analysis/analysis_progress.dart';

/// 正在分析的任务的进度（taskId → 进度）。
///
/// 刻意不落库：进度每几秒变一次，写进任务 JSON 等于把磁盘当日志用；而且
/// 应用退出后这份进度就失效了（已有「上次分析被中断」的恢复路径接住）。
class AnalysisProgressStore extends Notifier<Map<String, AnalysisProgress>> {
  @override
  Map<String, AnalysisProgress> build() => const {};

  void report(String taskId, AnalysisProgress progress) {
    if (state[taskId] == progress) return; // 同一份进度不重复通知，省掉无谓重绘
    state = {...state, taskId: progress};
  }

  /// 分析结束（成功或失败）后清掉，避免卡片一直挂着最后一步的文案
  void clear(String taskId) {
    if (!state.containsKey(taskId)) return;
    state = {
      for (final entry in state.entries)
        if (entry.key != taskId) entry.key: entry.value
    };
  }
}

final analysisProgressProvider =
    NotifierProvider<AnalysisProgressStore, Map<String, AnalysisProgress>>(
        AnalysisProgressStore.new);

/// 单条任务的进度。用 select 是为了让一条任务的进度变化只重绘它自己的卡片，
/// 而不是整个列表——分析中的任务每几秒就会推一次进度。
ProviderListenable<AnalysisProgress?> taskProgressOf(String taskId) =>
    analysisProgressProvider.select((map) => map[taskId]);
