import 'dart:async';
import 'package:characters/characters.dart';
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
  /// 正在分析中的任务 id 集合：并发守卫。同一任务 id 若已在集合中，
  /// 新的分析触发（自动分析 or 手动重试）一律忽略，避免用户快速连点
  /// 或「自动分析未完成时手动重试」两条路径对同一 workDir/源文件并发
  /// 重复跑 ffmpeg/ASR。
  final Set<String> _analyzingTaskIds = {};

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
    if (!_analyzingTaskIds.add(task.id)) {
      AppLog.info('任务 ${task.id} 分析已在进行中，忽略重复触发（并发守卫）');
      return;
    }
    unawaited(_runAnalyze(pipeline, task));
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

  /// 码点安全截断：Dart String 按 UTF-16 code unit 索引，朴素 substring
  /// 可能切在代理对（surrogate pair）中间，留下落单的 high surrogate，
  /// 写盘 UTF-8 编码时会被静默替换为 U+FFFD。改用 Characters 按用户可感知
  /// 字符（grapheme cluster）截断，天然不会切碎代理对或组合字符。
  String _truncateAnalysisError(Object error) {
    final message = error.toString();
    final characters = message.characters;
    return characters.length > _maxAnalysisErrorLength
        ? characters.take(_maxAnalysisErrorLength).toString()
        : message;
  }

  /// 实际执行一次分析（调用方需已完成 `_analyzingTaskIds` 守卫占位）；
  /// 无论成功或失败，结束时都在 finally 中释放守卫，避免占位泄漏导致
  /// 任务永久无法再次触发分析。
  Future<void> _runAnalyze(AnalysisPipeline pipeline, RenewTask task) async {
    try {
      await pipeline.analyze(task);
      await reload();
    } catch (e) {
      AppLog.warn('任务 ${task.id} 分析失败：$e');
      await _markAnalysisFailed(task, e);
    } finally {
      _analyzingTaskIds.remove(task.id);
    }
  }

  /// 分析失败后手动重试：清空 analysisError、状态置回 analyzing 并落库刷新，
  /// 随后重新触发分析管线；管线未配置（凭据缺失）时记录告警并直接返回；
  /// 若该任务已在分析中（并发守卫命中，例如用户快速连点或自动分析尚未
  /// 完成）则忽略本次触发，不重复跑 ffmpeg/ASR。
  Future<void> retryAnalysis(RenewTask task) async {
    final pipeline = ref.read(analysisPipelineProvider);
    if (pipeline == null) {
      AppLog.warn('任务 ${task.id} 重试分析已跳过：分析管线未配置');
      return;
    }
    if (!_analyzingTaskIds.add(task.id)) {
      AppLog.info('任务 ${task.id} 分析已在进行中，忽略重复触发（并发守卫）');
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

    unawaited(_runAnalyze(pipeline, resetTask));
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
