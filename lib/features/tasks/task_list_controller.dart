import 'dart:async';
import 'package:characters/characters.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/analysis/analysis_pipeline.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_repository.dart';
import '../import_flow/import_service.dart';
import 'task_artifact_cleaner.dart';

/// 由 main.dart（或测试）override 提供实例
final taskRepositoryProvider = Provider<TaskRepository>(
    (ref) => throw UnimplementedError('在 ProviderScope 中 override'));
final importServiceProvider = Provider<ImportService>(
    (ref) => throw UnimplementedError('在 ProviderScope 中 override'));

/// 分析管线：null 表示凭据未配置，导入后跳过自动分析（main.dart 按凭据完整性 override）
final analysisPipelineProvider = Provider<AnalysisPipeline?>((ref) => null);

/// 任务中间产物清理器：null 表示未接线（测试场景），删除任务时只删记录
final taskArtifactCleanerProvider = Provider<TaskArtifactCleaner?>((ref) => null);

/// 分析失败原因落库前的最大长度，避免超长堆栈/报错文本污染任务 JSON
const _maxAnalysisErrorLength = 300;

/// 上次运行中途退出留下的「分析中」任务，装载时写入此原因，
/// 使其能走已有的失败重试路径（不新增状态枚举值——新增会让旧版本读不出）
const stalledAnalysisMessage = '上次分析被中断（应用退出或异常关闭），请重新分析';

/// 分析管线不可用（AI 凭据缺失）时写入任务的原因，面向用户不含技术黑话
const pipelineUnavailableMessage = 'AI 服务未配置，无法自动分析。请补齐凭据后重启应用再重试。';

/// 触发分析的结果，供 UI 给出对应反馈（不能静默 return，否则用户点了没反应）
enum RetryOutcome {
  /// 已开始分析
  started,

  /// 该任务已有分析在进行中，忽略本次触发
  alreadyRunning,

  /// 分析管线不可用（AI 未配置）
  pipelineUnavailable,
}

class TaskListController extends AsyncNotifier<List<RenewTask>> {
  /// 正在分析中的任务 id 集合：并发守卫。同一任务 id 若已在集合中，
  /// 新的分析触发（自动分析 or 手动重试）一律忽略，避免用户快速连点
  /// 或「自动分析未完成时手动重试」两条路径对同一 workDir/源文件并发
  /// 重复跑 ffmpeg/ASR。
  final Set<String> _analyzingTaskIds = {};

  /// 最近一次装载中被跳过的损坏任务文件数（供列表页常驻提示；只写日志的话
  /// 用户看到的只是「我的任务不见了」）
  int _skippedTaskFileCount = 0;
  int get skippedTaskFileCount => _skippedTaskFileCount;

  @override
  Future<List<RenewTask>> build() async {
    final tasks = await _findAll();
    return _recoverStalledTasks(tasks);
  }

  Future<List<RenewTask>> _findAll() async {
    final repo = ref.read(taskRepositoryProvider);
    final tasks = await repo.findAll();
    // TaskLoadDiagnostics 与 TaskRepository 无继承关系，用模式匹配取诊断信息
    _skippedTaskFileCount = switch (repo) {
      TaskLoadDiagnostics(:final skippedTaskFileCount) => skippedTaskFileCount,
      _ => 0,
    };
    return tasks;
  }

  /// 启动装载：把「状态仍是分析中、又没有任何进行中分析」的任务标记为已中断。
  ///
  /// 分析是纯内存态的后台任务（unawaited），进程一关就没了，而任务状态停在
  /// analyzing 且 analysisError 为 null——列表只显示「分析中」、点开只提示
  /// 「请稍候」、重试入口又只在有 analysisError 时出现，用户走进死路。
  /// 只在 build（启动装载）做，reload 不做，避免把本次运行中真正在分析的
  /// 任务误标为中断。
  Future<List<RenewTask>> _recoverStalledTasks(List<RenewTask> tasks) async {
    final repo = ref.read(taskRepositoryProvider);
    final recovered = <RenewTask>[];
    for (final task in tasks) {
      if (!_isStalled(task)) {
        recovered.add(task);
        continue;
      }
      final marked = task.copyWith(analysisError: stalledAnalysisMessage);
      try {
        await repo.save(marked);
        AppLog.warn('任务 ${task.id} 上次分析被中断，已标记为可重试');
      } catch (e) {
        // 落库失败不影响本次展示，下次启动会再尝试
        AppLog.warn('任务 ${task.id} 中断标记落库失败：$e');
      }
      recovered.add(marked);
    }
    return List.unmodifiable(recovered);
  }

  bool _isStalled(RenewTask task) =>
      task.status == RenewTaskStatus.analyzing &&
      task.analysisError == null &&
      !_analyzingTaskIds.contains(task.id);

  /// 删除任务：先清理中间产物（失败不阻断），再删记录并从列表中移除那一条
  Future<void> deleteTask(RenewTask task) async {
    try {
      await ref.read(taskArtifactCleanerProvider)?.cleanup(task.id);
    } catch (e) {
      AppLog.warn('任务 ${task.id} 中间产物清理失败（不影响删除）：$e');
    }
    await ref.read(taskRepositoryProvider).delete(task.id);
    if (!_removeLocally(task.id)) await reload();
  }

  /// 重命名：空白名称视为无效输入，直接忽略（调用方在 UI 层已给出提示）
  Future<void> renameTask(RenewTask task, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      AppLog.warn('任务 ${task.id} 重命名已忽略：名称为空');
      return;
    }
    final renamed = task.copyWith(name: trimmed, updatedAt: DateTime.now());
    await ref.read(taskRepositoryProvider).save(renamed);
    await _refreshAfterSave(renamed);
  }

  /// 全量重新装载。
  ///
  /// 用 `copyWithPrevious` 保留上一份数据：直接置 `AsyncLoading()` 会把 value
  /// 抹成 null，列表页据此渲染整页 spinner——于是「确认切分」「保存草稿」这类
  /// 只动一条任务的操作，也会让整个任务网格白屏闪一下。保留旧数据后，加载中
  /// 只是 `isRefreshing`，页面继续显示旧列表直到新数据就绪。
  Future<void> reload() async {
    state = const AsyncLoading<List<RenewTask>>().copyWithPrevious(state);
    state = await AsyncValue.guard(_findAll);
  }

  /// 保存单条任务后刷新列表：优先局部更新，只有在列表尚未装载出来（还在
  /// loading 或上次装载出错）时才退回全量重读。
  ///
  /// 全量重读会遍历任务目录并把每条任务 JSON 完整解码重建对象——实测约
  /// 1 ms/任务（96 秒素材，40 KB JSON），5 分钟素材外推约 3.5 ms/任务；
  /// 而「保存草稿」在审片台里是高频操作，每次都付这份钱不划算。
  Future<void> _refreshAfterSave(RenewTask updated) async {
    if (!_upsertLocally(updated)) await reload();
  }

  /// 就地替换（或插入）一条任务，返回是否成功应用局部更新。
  ///
  /// 全程不可变：构造新列表而不改动原列表。
  bool _upsertLocally(RenewTask updated) {
    final current = state.valueOrNull;
    if (current == null) return false;
    final rest = current.where((t) => t.id != updated.id).toList(growable: false);
    state = AsyncData(List.unmodifiable(_insertByUpdatedAtDesc(rest, updated)));
    return true;
  }

  /// 从列表中移除一条任务，返回是否成功应用局部更新
  bool _removeLocally(String id) {
    final current = state.valueOrNull;
    if (current == null) return false;
    state = AsyncData(
        List.unmodifiable(current.where((t) => t.id != id).toList()));
    return true;
  }

  /// 按 updatedAt 倒序插入，与 FileTaskRepository.findAll 的排序口径一致。
  ///
  /// 用「找插入位」而不是整表 sort：Dart 的 List.sort 不保证稳定，updatedAt
  /// 相同的任务会被随机重排，用户会看到列表无缘无故跳动。
  static List<RenewTask> _insertByUpdatedAtDesc(
      List<RenewTask> sorted, RenewTask task) {
    final at = sorted.indexWhere((t) => t.updatedAt.isBefore(task.updatedAt));
    final index = at < 0 ? sorted.length : at;
    return [...sorted.take(index), task, ...sorted.skip(index)];
  }

  /// 导入并自动分析。[unitTagGroup] / [shotTagGroup] 是新建向导选定的两个
  /// miaoa 标签组，随任务落库，分析时据此解析各自的受控词表。
  Future<void> importFile(
    String path, {
    TagGroupRef? unitTagGroup,
    TagGroupRef? shotTagGroup,
  }) async {
    final task = await ref.read(importServiceProvider).importLocalFile(
          path,
          unitTagGroup: unitTagGroup,
          shotTagGroup: shotTagGroup,
        );
    await reload();

    final pipeline = ref.read(analysisPipelineProvider);
    if (pipeline == null) {
      // 不能静默返回：任务会永远停在「分析中」，且因 analysisError 为空
      // 连重试入口都够不到
      AppLog.warn('任务 ${task.id} 未自动分析：分析管线未配置');
      await _markAnalysisFailed(task, pipelineUnavailableMessage);
      return;
    }
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
  Future<RetryOutcome> retryAnalysis(RenewTask task) async {
    final pipeline = ref.read(analysisPipelineProvider);
    if (pipeline == null) {
      AppLog.warn('任务 ${task.id} 重试分析已跳过：分析管线未配置');
      await _markAnalysisFailed(task, pipelineUnavailableMessage);
      return RetryOutcome.pipelineUnavailable;
    }
    if (!_analyzingTaskIds.add(task.id)) {
      AppLog.info('任务 ${task.id} 分析已在进行中，忽略重复触发（并发守卫）');
      return RetryOutcome.alreadyRunning;
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
    return RetryOutcome.started;
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
    await _refreshAfterSave(updated);
  }

  /// 审片台「保存草稿」：仅保存编辑后的 units，不改变任务状态
  Future<void> saveSegmentationDraft(
      RenewTask task, List<SemanticUnit> units) async {
    final updated = task.copyWith(units: units, updatedAt: DateTime.now());
    await ref.read(taskRepositoryProvider).save(updated);
    await _refreshAfterSave(updated);
  }
}

final taskListProvider =
    AsyncNotifierProvider<TaskListController, List<RenewTask>>(
        TaskListController.new);
