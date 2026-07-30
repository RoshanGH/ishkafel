import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/analysis/analysis_pipeline.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/storage/task_repository.dart';
import '../import_flow/import_service.dart';

/// 由 main.dart（或测试）override 提供实例
final taskRepositoryProvider = Provider<TaskRepository>(
    (ref) => throw UnimplementedError('在 ProviderScope 中 override'));
final importServiceProvider = Provider<ImportService>(
    (ref) => throw UnimplementedError('在 ProviderScope 中 override'));

/// 分析管线：null 表示凭据未配置，导入后跳过自动分析（main.dart 按凭据完整性 override）
final analysisPipelineProvider = Provider<AnalysisPipeline?>((ref) => null);

/// 分析失败原因落库前的最大长度，避免超长堆栈/报错文本污染任务 JSON
const _maxAnalysisErrorLength = 300;

class TaskListController extends AsyncNotifier<List<RenewTask>> {
  @override
  Future<List<RenewTask>> build() => ref.read(taskRepositoryProvider).findAll();

  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
        () => ref.read(taskRepositoryProvider).findAll());
  }

  Future<void> importFile(String path) async {
    final task = await ref.read(importServiceProvider).importLocalFile(path);
    await reload();

    final pipeline = ref.read(analysisPipelineProvider);
    if (pipeline == null) return;
    unawaited(pipeline.analyze(task).then((_) => reload()).catchError((e) async {
      AppLog.warn('任务 ${task.id} 自动分析失败：$e');
      await _markAnalysisFailed(task, e);
    }));
  }

  /// 分析失败反馈：落库 analysisError（保持原状态，通常仍是 analyzing），
  /// 供任务列表展示红色失败徽标并支持用户手动重试
  Future<void> _markAnalysisFailed(RenewTask task, Object error) async {
    final repo = ref.read(taskRepositoryProvider);
    final current = await repo.findById(task.id) ?? task;
    final failed = current.copyWith(
      analysisError: _truncateAnalysisError(error),
      updatedAt: DateTime.now(),
    );
    await repo.save(failed);
    await reload();
  }

  String _truncateAnalysisError(Object error) {
    final message = error.toString();
    return message.length > _maxAnalysisErrorLength
        ? message.substring(0, _maxAnalysisErrorLength)
        : message;
  }

  /// 分析失败后手动重试：清空 analysisError、状态置回 analyzing 并落库刷新，
  /// 随后重新触发分析管线；管线未配置（凭据缺失）时记录告警并直接返回。
  Future<void> retryAnalysis(RenewTask task) async {
    final pipeline = ref.read(analysisPipelineProvider);
    if (pipeline == null) {
      AppLog.warn('任务 ${task.id} 重试分析已跳过：分析管线未配置');
      return;
    }

    final repo = ref.read(taskRepositoryProvider);
    final resetTask = task.copyWith(
      clearAnalysisError: true,
      status: RenewTaskStatus.analyzing,
      updatedAt: DateTime.now(),
    );
    await repo.save(resetTask);
    await reload();

    unawaited(
        pipeline.analyze(resetTask).then((_) => reload()).catchError((e) async {
      AppLog.warn('任务 ${resetTask.id} 重试分析失败：$e');
      await _markAnalysisFailed(resetTask, e);
    }));
  }

  /// 审片台「确认切分」：保存编辑后的 units 并流转到「选材中」状态，随后刷新列表
  Future<void> confirmSegmentation(
      RenewTask task, List<SemanticUnit> units) async {
    final updated = task.copyWith(
      units: units,
      status: RenewTaskStatus.picking,
      updatedAt: DateTime.now(),
    );
    await ref.read(taskRepositoryProvider).save(updated);
    await reload();
  }

  /// 审片台「保存草稿」：仅保存编辑后的 units，不改变任务状态
  Future<void> saveSegmentationDraft(
      RenewTask task, List<SemanticUnit> units) async {
    final updated = task.copyWith(units: units, updatedAt: DateTime.now());
    await ref.read(taskRepositoryProvider).save(updated);
    await reload();
  }
}

final taskListProvider =
    AsyncNotifierProvider<TaskListController, List<RenewTask>>(
        TaskListController.new);
