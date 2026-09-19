import 'dart:async';
import 'package:characters/characters.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/analysis/analysis_pipeline.dart';
import '../../core/analysis/tagging_service.dart';
import '../../core/audio/bgm_plan.dart';
import '../../core/editing/segmentation_change.dart';
import '../../core/audio/vocal_separator.dart';
import '../../core/audio/voice_plan.dart';
import '../../core/log/app_log.dart';
import '../../core/models/project_ref.dart';
import '../../cli/busy_guard.dart';
import '../agent/app_busy_holder.dart';
import '../../core/storage/task_copy.dart';
import '../settings/settings_providers.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/models/unit_uid.dart';
import '../../core/models/export_record.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/replacement/replacement_plan.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_log.dart';
import '../../core/storage/task_mutation.dart';
import '../../core/storage/task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../../core/subtitle/subtitle_track.dart';
import '../import_flow/import_service.dart';
import 'analysis_error_message.dart';
import 'gui_task_mutation.dart';
import 'analysis_progress_store.dart';
import '../../core/analysis/base_transcriber.dart';
import '../../core/analysis/unit_segmenter.dart';
import 'task_artifact_cleaner.dart';
import 'task_list_merge.dart';

/// 由 main.dart（或测试）override 提供实例
final taskRepositoryProvider = Provider<TaskRepository>(
    (ref) => throw UnimplementedError('在 ProviderScope 中 override'));
final importServiceProvider = Provider<ImportService>(
    (ref) => throw UnimplementedError('在 ProviderScope 中 override'));

/// 分析管线：null 表示凭据未配置，导入后跳过自动分析（main.dart 按凭据完整性 override）
final analysisPipelineProvider = Provider<AnalysisPipeline?>((ref) => null);

/// 打标服务：工作台里「改完之后重新打标」直接用它，不必把整条分析管线
/// （抽音频、ASR、语义切分）再拖进来。缺省取自分析管线，凭据未配置时为 null。
final taggingServiceProvider = Provider<TaggingService?>(
    (ref) => ref.watch(analysisPipelineProvider)?.tagging);

/// 单段底片切分器：跟全片切分同一条链路（采信号 → 双判据 → 灰区画面复核），
/// 只是喂进去的视频换成了这一段自己的底片。null 表示凭据未配置
final unitSegmenterProvider = Provider<UnitSegmenter?>((ref) {
  final pipeline = ref.watch(analysisPipelineProvider);
  if (pipeline == null) return null;
  return UnitSegmenter(
      scenes: pipeline.scenes, boundaries: pipeline.shotBoundaries);
});

/// 底片转写器：给切开的那一段拿到它自己的词级时间戳——字幕这条线从头到尾
/// 建立在词级时间戳上，拿别的凑不出来。null 表示凭据未配置
final baseTranscriberProvider = Provider<BaseTranscriber?>((ref) {
  final pipeline = ref.watch(analysisPipelineProvider);
  if (pipeline == null) return null;
  return BaseTranscriber(
      audio: pipeline.audio, asr: pipeline.asr, workDir: pipeline.workDir);
});

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

  /// 该任务的记录已不在磁盘上（触发入口还停留在屏幕上时任务被删除了）
  taskMissing,
}

/// 重命名结果，供 UI 给出对应反馈
enum RenameOutcome {
  /// 已重命名
  renamed,

  /// 名称为空白，视为无效输入
  invalidName,

  /// 该任务的记录已不在磁盘上（对话框还开着时任务被删除了）
  taskMissing,
}

/// 工作台一次落库里「一个单元变了什么」：改前、改后，以及**改完之后它还在不在**。
///
/// `stillThere` 单独一格而不是靠 `after['present'] == false` 推——盖不盖戳
/// 这件事不该依赖读一个约定好的 map key，那种约定改一次就会悄悄失效。
typedef _UnitChange = ({
  String uid,
  Map<String, dynamic> before,
  Map<String, dynamic> after,
  bool stillThere,
});

/// 记录已被删除时给用户的说明（对话框/SnackBar 可能比任务活得更久）
const taskMissingMessage = '该任务已被删除，本次操作未生效。';

/// 任务列表整体装载失败时给用户的说明。
///
/// 不能把 `PathNotFoundException: Cannot open file, path = '...'
/// (OS Error: ..., errno = 2)` 这类原文摊给用户——它既不解释发生了什么，
/// 也不告诉用户能做什么。原始异常只进日志。
const taskLoadFailedMessage = '任务列表读取失败，可能是数据目录暂时无法访问。请点「重试」重新加载。';

class TaskListController extends AsyncNotifier<List<RenewTask>> {
  /// 人真的点出来的那些改动的写入口。**任务的每一次改动都从这儿走**。
  ///
  /// `actor` 说的是哪张台子，按方法给：`save*` 那一批全部来自工作台
  /// （唯一调用方是 `workbench_page.dart`），重命名/重试分析来自任务列表页。
  TaskMutation _mutation(String actor) => humanMutation(
        repo: ref.read(taskRepositoryProvider),
        dataDir: ref.read(dataDirProvider),
        actor: actor,
      );

  /// 软件自己干的活儿的写入口（`by` 是 agent，理由见 [softwareMutation]）：
  /// 启动自检、报告分析失败。**人没在这里做过任何决定**，标成「人」会让
  /// Agent 让步于一个不存在的人类决定。
  TaskMutation _selfMutation(String actor) => softwareMutation(
        repo: ref.read(taskRepositoryProvider),
        dataDir: ref.read(dataDirProvider),
        actor: actor,
      );

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
    // 老任务补短编号（#N，见 task_seq.dart）：幂等，只在启动装载做一次
    final numbered =
        await ensureTaskSeqs(ref.read(taskRepositoryProvider), tasks);
    return _recoverStalledTasks(numbered);
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
    final recovered = <RenewTask>[];
    for (final task in tasks) {
      // 陈旧的中断标记：状态已经回到 ready，说明后来分析成功了，
      // 那句「上次分析被中断」是上一轮留下的。不清掉的话，人看到的是一条
      // 完整可用的任务显示红色失败，点「重试」还要再花一次分析的钱
      if (task.status == RenewTaskStatus.ready &&
          task.analysisError == stalledAnalysisMessage) {
        recovered.add(await _clearStaleStalledMark(task));
        continue;
      }
      if (!_isStalled(task)) {
        recovered.add(task);
        continue;
      }
      recovered.add(await _markStalled(task));
    }
    return List.unmodifiable(recovered);
  }

  /// 清掉上一轮留下的陈旧中断标记。写不成不影响本次展示，下次启动再试
  Future<RenewTask> _clearStaleStalledMark(RenewTask task) async {
    try {
      final healed = await _selfMutation(actorSelfCheck).apply(
        taskId: task.id,
        op: 'analyze.stalled',
        note: '启动自检：上次那句「分析被中断」是陈旧的，分析其实成功了',
        edit: (fresh) {
          // 判据在 fresh 上重来一遍：这条任务从列表读出来到这一刻，
          // 外面可能已经重新分析过了
          if (fresh.status != RenewTaskStatus.ready ||
              fresh.analysisError != stalledAnalysisMessage) {
            return TaskEdit(
              task: fresh,
              before: {'analysisError': fresh.analysisError},
              after: {'note': '这条已经不是陈旧标记了，没动'},
            );
          }
          return TaskEdit(
            task: fresh.copyWith(clearAnalysisError: true),
            before: {
              'status': fresh.status.name,
              'analysisError': fresh.analysisError,
            },
            after: {'status': fresh.status.name, 'analysisError': null},
          );
        },
      );
      return healed ?? task.copyWith(clearAnalysisError: true);
    } catch (e) {
      AppLog.warn('任务 ${task.id} 清理陈旧中断标记失败：$e');
      return task.copyWith(clearAnalysisError: true);
    }
  }

  /// 把「状态停在分析中、又没有任何分析在跑」的任务标成可重试
  Future<RenewTask> _markStalled(RenewTask task) async {
    try {
      final marked = await _selfMutation(actorSelfCheck).apply(
        taskId: task.id,
        op: 'analyze.stalled',
        note: '启动自检：上次分析被中断（应用退出或异常关闭），标成可重试',
        edit: (fresh) {
          if (fresh.status != RenewTaskStatus.analyzing ||
              fresh.analysisError != null) {
            return TaskEdit(
              task: fresh,
              before: {'status': fresh.status.name},
              after: {'note': '这条已经不停在「分析中」了，没动'},
            );
          }
          return TaskEdit(
            task: fresh.copyWith(analysisError: stalledAnalysisMessage),
            before: {'status': fresh.status.name, 'analysisError': null},
            after: {
              'status': fresh.status.name,
              'analysisError': stalledAnalysisMessage,
            },
          );
        },
      );
      AppLog.warn('任务 ${task.id} 上次分析被中断，已标记为可重试');
      return marked ?? task.copyWith(analysisError: stalledAnalysisMessage);
    } catch (e) {
      // 落库失败不影响本次展示，下次启动会再尝试
      AppLog.warn('任务 ${task.id} 中断标记落库失败：$e');
      return task.copyWith(analysisError: stalledAnalysisMessage);
    }
  }

  bool _isStalled(RenewTask task) =>
      task.status == RenewTaskStatus.analyzing &&
      task.analysisError == null &&
      !_analyzingTaskIds.contains(task.id);

  /// 本次运行中已被删除的任务 id（墓碑）。
  ///
  /// id 由导入时刻的微秒时间戳生成，单调递增、不会被复用，因此墓碑不会误伤
  /// 后续新建的任务；每条只占一个短字符串，一次会话内的删除量级可忽略。
  final Set<String> _deletedTaskIds = {};

  /// 删除任务：先清理中间产物（失败不阻断），再删记录并从列表中移除那一条
  Future<void> deleteTask(RenewTask task) async {
    // 墓碑要在任何 await 之前立起来：清理与删记录都是异步的，期间到达的
    // 「重试/重命名/分析失败落库」必须立刻被拒绝，否则会把它重新写回磁盘
    _deletedTaskIds.add(task.id);
    try {
      await ref.read(taskArtifactCleanerProvider)?.cleanup(task.id);
    } catch (e) {
      AppLog.warn('任务 ${task.id} 中间产物清理失败（不影响删除）：$e');
    }
    try {
      await ref.read(taskRepositoryProvider).delete(task.id);
    } catch (e) {
      // 没删成功，任务还在磁盘上，墓碑必须撤掉，否则这条任务本次会话
      // 再也无法重命名/重试（等于把 Critical 2 那类死锁换个地方复现）
      _deletedTaskIds.remove(task.id);
      rethrow;
    }
    // 改动日志已登记进 TaskArtifacts（跟 covers 同款：按任务命名的单文件），
    // 上面 taskArtifactCleanerProvider 那次清理已经带走了它，这里不用再删一次
    if (!_removeLocally(task.id)) await reload();
  }

  /// 重命名：空白名称视为无效输入，直接忽略（调用方在 UI 层已给出提示）。
  ///
  /// 以磁盘上的当前记录为基线，而不是调用方传进来的 [task]：重命名对话框
  /// 可以长时间停留，期间后台分析可能已经写入了 units/新状态，拿旧快照
  /// copyWith 会把这些成果一并抹掉。记录已不存在时不落库（见 [_currentRecord]）。
  /// 复制一条任务。返回新任务；源任务已被删掉时返回 null。
  ///
  /// **两条任务此后完全隔离**——该带走的产物一并复制、任务里存的路径全部
  /// 改写到新任务名下（见 [TaskCopier]）。
  Future<RenewTask?> copyTask(RenewTask task) async {
    final current = await _currentRecord(task, action: '复制');
    if (current == null) return null;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return null;
    final repository = ref.read(taskRepositoryProvider);
    final all = await repository.findAll();
    final copy = await TaskCopier(dataDir).duplicate(
      current,
      // 和导入那条路同一个身份生成方式（见 ImportService._defaultId）
      newId: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      seq: await nextTaskSeq(repository),
      now: DateTime.now(),
      name: copiedTaskName(current.name, [for (final t in all) t.name]),
    );
    await repository.save(copy);
    await _refreshAfterSave(copy);
    return copy;
  }

  Future<RenameOutcome> renameTask(RenewTask task, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      AppLog.warn('任务 ${task.id} 重命名已忽略：名称为空');
      return RenameOutcome.invalidName;
    }
    final current = await _currentRecord(task, action: '重命名');
    if (current == null) return RenameOutcome.taskMissing;
    final renamed = await _mutation(actorTaskList).apply(
      taskId: current.id,
      op: 'task.rename',
      edit: (fresh) => TaskEdit(
        task: fresh.copyWith(name: trimmed),
        before: {'name': fresh.name},
        after: {'name': trimmed},
      ),
    );
    if (renamed == null) return RenameOutcome.taskMissing;
    await _refreshAfterSave(renamed);
    return RenameOutcome.renamed;
  }

  /// 读取磁盘上仍然存在的那条记录；已被删除时返回 null 并落日志。
  ///
  /// `save` 是「有则覆盖、无则创建」，对已删除的 id 等于重新创建一条——而
  /// 它的封面、PCM、抽帧在删除时已被清理器删掉，复活出来的任务不会自愈。
  /// 触发入口（带「重试」的 SnackBar、重命名对话框）都可能比任务本身活得
  /// 更久，因此每次「更新已有任务」前都要先确认记录还在。
  ///
  /// 两道判定缺一不可：
  /// - 查磁盘：覆盖「上次运行删掉、本次运行还拿着旧对象」这类跨进程情形，
  ///   同时顺带取回最新记录，避免用陈旧快照覆盖磁盘上的新数据；
  /// - 查 [_deletedTaskIds]：查存在性本身是 check-then-act，删除若发生在
  ///   「查完」与「写入」之间仍会复活（后台分析失败落库尤其容易撞上）。
  ///
  /// 导入新任务不经过这里（它本来就该创建记录），因此不会被误伤。
  Future<RenewTask?> _currentRecord(RenewTask task,
      {required String action}) async {
    final current = _deletedTaskIds.contains(task.id)
        ? null
        : await ref.read(taskRepositoryProvider).findById(task.id);
    if (current == null || _deletedTaskIds.contains(task.id)) {
      AppLog.warn('任务 ${task.id} $action已跳过：记录已被删除，不再写回磁盘');
      return null;
    }
    return current;
  }

  /// 全量重新装载。
  ///
  /// 用 `copyWithPrevious` 保留上一份数据：直接置 `AsyncLoading()` 会把 value
  /// 抹成 null，列表页据此渲染整页 spinner——于是「确认切分」「保存草稿」这类
  /// 只动一条任务的操作，也会让整个任务网格白屏闪一下。保留旧数据后，加载中
  /// 只是 `isRefreshing`，页面继续显示旧列表直到新数据就绪。
  Future<void> reload() async {
    state = const AsyncLoading<List<RenewTask>>().copyWithPrevious(state);
    // 记下起步代次：这之后发生的局部更新不在这份快照里，回写前要叠加回去
    final since = _localChangeGeneration;
    _reloadsInFlight++;
    try {
      final snapshot = await _findAll();
      state = AsyncData(List.unmodifiable(mergeLocalChanges(
        snapshot: snapshot,
        changes: _localChanges,
        since: since,
      )));
    } catch (e, stackTrace) {
      // 原始异常（PathNotFoundException + errno 之类）只进日志：
      // AsyncValue.guard 会把它静默塞进 state，页面再原样摊给用户
      AppLog.warn('任务列表装载失败：$e');
      state = AsyncError(e, stackTrace);
    } finally {
      _reloadsInFlight--;
      // 没有 reload 在飞时这些记录就没人再用了，及时清空防止无界增长
      if (_reloadsInFlight == 0) _localChanges.clear();
    }
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
    state = AsyncData(List.unmodifiable(insertByUpdatedAtDesc(rest, updated)));
    _recordLocalChange(updated.id, updated);
    return true;
  }

  /// 从列表中移除一条任务，返回是否成功应用局部更新
  bool _removeLocally(String id) {
    final current = state.valueOrNull;
    if (current == null) return false;
    state = AsyncData(
        List.unmodifiable(current.where((t) => t.id != id).toList()));
    _recordLocalChange(id, null);
    return true;
  }

  /// 代次号：每次局部更新自增，[reload] 用它判断哪些更新发生在自己起步之后
  int _localChangeGeneration = 0;

  /// 正在进行中的 reload 数量（可能有多个并发：后台分析结束 + 用户操作）
  int _reloadsInFlight = 0;

  /// 有 reload 在飞时才需要留档，否则记录立刻就没人用了
  final List<LocalTaskChange> _localChanges = [];

  void _recordLocalChange(String id, RenewTask? task) {
    _localChangeGeneration++;
    if (_reloadsInFlight == 0) return;
    _localChanges.add(LocalTaskChange(
        generation: _localChangeGeneration, id: id, task: task));
  }

  /// 导入并自动分析。[unitTagGroups] / [shotTagGroups] 是新建向导选定的两层
  /// miaoa 标签组，随任务落库，分析时据此解析各自的受控词表。
  /// 建一条空白任务。**不排分析**——没有原片可分析，建出来直接可编辑
  Future<RenewTask> createBlankTask({
    required String name,
    List<TagGroupRef> unitTagGroups = const [],
    List<TagGroupRef> shotTagGroups = const [],
    String unitTagPrompt = '',
    String shotTagPrompt = '',
    ProjectRef? project,
  }) async {
    final task = await ref.read(importServiceProvider).createBlank(
          name: name,
          project: project,
          unitTagGroups: unitTagGroups,
          shotTagGroups: shotTagGroups,
          unitTagPrompt: unitTagPrompt,
          shotTagPrompt: shotTagPrompt,
        );
    await reload();
    // 把建出来的那条报回去：调用方（尤其是 Agent 那条路）得知道是哪一条，
    // 而不是建完去任务库里翻「最新的那条」猜
    return task;
  }

  /// 建一条脚本成片任务。**不排分析**——脚本从空白写起，建出来直接进编导台
  Future<RenewTask> createScriptTask({
    required String name,
    List<TagGroupRef> unitTagGroups = const [],
    List<TagGroupRef> shotTagGroups = const [],
    String unitTagPrompt = '',
    String shotTagPrompt = '',
    ProjectRef? project,
  }) async {
    final task = await ref.read(importServiceProvider).createScript(
          name: name,
          project: project,
          unitTagGroups: unitTagGroups,
          shotTagGroups: shotTagGroups,
          unitTagPrompt: unitTagPrompt,
          shotTagPrompt: shotTagPrompt,
        );
    await reload();
    return task;
  }

  Future<RenewTask?> importFile(
    String path, {
    List<TagGroupRef> unitTagGroups = const [],
    List<TagGroupRef> shotTagGroups = const [],
    String unitTagPrompt = '',
    String shotTagPrompt = '',
    ProjectRef? project,
  }) async {
    final task = await ref.read(importServiceProvider).importLocalFile(
          path,
          project: project,
          unitTagGroups: unitTagGroups,
          shotTagGroups: shotTagGroups,
          unitTagPrompt: unitTagPrompt,
          shotTagPrompt: shotTagPrompt,
        );
    await reload();

    final pipeline = ref.read(analysisPipelineProvider);
    if (pipeline == null) {
      // 不能静默返回：任务会永远停在「分析中」，且因 analysisError 为空
      // 连重试入口都够不到
      AppLog.warn('任务 ${task.id} 未自动分析：分析管线未配置');
      await _markAnalysisFailed(task, pipelineUnavailableMessage);
      // 任务本身建出来了，只是没能自动分析——照样把它报回去
      return task;
    }
    if (!_analyzingTaskIds.add(task.id)) {
      AppLog.info('任务 ${task.id} 分析已在进行中，忽略重复触发（并发守卫）');
      return task;
    }
    unawaited(_runAnalyze(pipeline, task));
    return task;
  }

  /// 分析失败反馈：落库 analysisError（保持原状态，通常仍是 analyzing），
  /// 供任务列表展示红色失败徽标并支持用户手动重试
  Future<void> _markAnalysisFailed(RenewTask task, Object error) async {
    // 分析期间任务可能已被删除：失败落库不能把它复活
    final current = await _currentRecord(task, action: '分析失败落库');
    if (current == null) return;
    final message = _truncateAnalysisError(error);
    // **软件在报事实，不是人的判断**：这句失败原因是管线抛出来的，
    // 标成「人」会让 Agent 把它当成人的诊断
    await _selfMutation(actorAnalysisReport).apply(
      taskId: current.id,
      op: 'analyze.failed',
      edit: (fresh) => TaskEdit(
        task: fresh.copyWith(analysisError: message),
        before: {
          'status': fresh.status.name,
          'analysisError': fresh.analysisError,
        },
        // 状态不动（通常仍是 analyzing）：重试入口认的就是这个组合
        after: {'status': fresh.status.name, 'analysisError': message},
      ),
    );
    await reload();
  }

  /// 翻译成中文人话后再做码点安全截断。
  ///
  /// 码点安全：Dart String 按 UTF-16 code unit 索引，朴素 substring 可能切在
  /// 代理对（surrogate pair）中间，留下落单的 high surrogate，写盘 UTF-8
  /// 编码时会被静默替换为 U+FFFD。改用 Characters 按用户可感知字符
  /// （grapheme cluster）截断，天然不会切碎代理对或组合字符。
  String _truncateAnalysisError(Object error) {
    final message = describeAnalysisError(error);
    final characters = message.characters;
    return characters.length > _maxAnalysisErrorLength
        ? characters.take(_maxAnalysisErrorLength).toString()
        : message;
  }

  /// 实际执行一次分析（调用方需已完成 `_analyzingTaskIds` 守卫占位）；
  /// 无论成功或失败，结束时都在 finally 中释放守卫，避免占位泄漏导致
  /// 任务永久无法再次触发分析。
  Future<void> _runAnalyze(AnalysisPipeline pipeline, RenewTask task) async {
    final progress = ref.read(analysisProgressProvider.notifier);
    // **界面自己跑分析也要报「在忙」，但报在另一条通道上。**
    //
    // 不报的话，`ishkafel analyze` 那道「别把同一条管线跑两遍」的劝告认不出
    // 这一边——人在界面上点了分析、Agent 同时敲了 `analyze`，整条管线
    // （ASR + LLM 切分 + 逐镜打标，几分钟、按量计费）跑两遍。
    // **锁删掉之前这一条是锁挡着的，删了就得接住。**
    //
    // 但**不能写 Agent 那份在场状态**（`writeAgentPresence`）：那条是播报
    // 通道，CLAUDE.md 明令「软件自己跑的活儿不许占那条通道——占了，人就
    // 分不清是谁在动手」；而且两边共用一个文件会互相覆盖、互相抹掉。
    // 所以走 `writeAppBusy` 那一份，判据两份都看（见 `busy_guard.dart`）。
    //
    // 判据认的是 action 里的「分析」两个字，所以用 busy_guard 那份常量拼，
    // 别手写——手写的话改一句文案，判据会静默失效
    // 心跳、嵌套、收工都交给 AppBusyHolder——**不再手写一份**。
    // 手写的那版和编导台那版是两套各写各的，而「不留缝」「话不能变空」
    // 「dispose 之后的回调不许乱减计数」这几条只在一处被守住过
    final dataDir = ref.read(dataDirProvider);
    final busy = dataDir == null
        ? null
        : AppBusyHolder(
            dataDir: dataDir, taskId: task.id, holder: actorAnalysisReport);
    // 外层挂整轮：进度是**按阶段**发的，每阶段一次，而 `building` 之后的
    // 逐镜打标实测七十多秒——超过 60 秒的失效线。里面每换一步再挂一层，
    // 两层之间不留缝
    var release = busy?.enter('正在$analyzeBusyKeyword原片') ?? () {};
    try {
      await pipeline.analyze(
        task,
        // **切出来的单元、打上的标签都是机器产的**，不是人的判断——
        // 人点的那一下有它自己那一笔（analyze.retry，human / 人（任务列表））。
        // 标成人会让 Agent 以为这些边界是有人亲手定的，从此不敢动
        by: ActorKind.agent,
        actor: actorAnalysisReport,
        onProgress: (p) {
          progress.report(task.id, p);
          // 换一步就换一层：先挂新的再放旧的，**中间不留缝**。
          // 不换步的那几十秒靠 AppBusyHolder 自己的心跳续着
          final next =
              busy?.enter('正在$analyzeBusyKeyword原片：${p.stage.name}') ?? () {};
          release();
          release = next;
        },
        // 切分一好就刷新列表：那一刻任务已经能打开干活了，剩下的打标
        // 在后台补。让人对着「分析中」多等三倍时间没道理。
        onUnitsReady: (_) => unawaited(reload()),
      );
      await reload();
    } catch (e) {
      AppLog.warn('任务 ${task.id} 分析失败：$e');
      await _markAnalysisFailed(task, e);
    } finally {
      // 成功与失败都要清：留着最后一步的文案，卡片看起来像还在跑
      progress.clear(task.id);
      _analyzingTaskIds.remove(task.id);
      // 在忙状态也要撤——不撤的话接下来 60 秒里 Agent 的 analyze
      // 会被一条**已经结束**的活儿劝退
      release();
      busy?.dispose();
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

    // 守卫占位后到 _runAnalyze 真正接管之间的任何异常（磁盘写满、数据目录
    // 只读）都必须先释放占位再冒泡：否则 _runAnalyze 的 finally 根本没机会
    // 执行，该 id 会永远留在集合里，用户后续每次重试都被告知「正在分析中」，
    // 而实际上没有任何分析在跑，整个进程生命周期内该任务的分析入口失效。
    final RenewTask resetTask;
    try {
      // 记录已被删除时不重建：SnackBar 上的「重试」可能比任务活得更久
      final current = await _currentRecord(task, action: '重试分析');
      if (current == null) {
        _analyzingTaskIds.remove(task.id);
        return RetryOutcome.taskMissing;
      }
      final reset = await _mutation(actorTaskList).apply(
        taskId: current.id,
        op: 'analyze.retry',
        note: '人在任务列表点了「重试分析」',
        edit: (fresh) => TaskEdit(
          task: fresh.copyWith(
            clearAnalysisError: true,
            status: RenewTaskStatus.analyzing,
          ),
          before: {
            'status': fresh.status.name,
            'analysisError': fresh.analysisError,
          },
          after: {
            'status': RenewTaskStatus.analyzing.name,
            'analysisError': null,
          },
        ),
      );
      if (reset == null) {
        // 写之前那一刻任务被删了。_currentRecord 查过一次，这是第二道
        _analyzingTaskIds.remove(task.id);
        return RetryOutcome.taskMissing;
      }
      resetTask = reset;
      await reload();
    } catch (e) {
      _analyzingTaskIds.remove(task.id);
      rethrow;
    }

    unawaited(_runAnalyze(pipeline, resetTask));
    return RetryOutcome.started;
  }

  /// 「替换选材」：保存各台词语义单元的替换方案。
  ///
  /// 不改变任务状态——状态要等阶段③真正导出后才该流转到 exported，
  /// 提前改会让任务在列表里显示成已导出却拿不到成片。
  /// [replacements] 按位置排（界面就是这么摆的），落库时翻译成
  /// 「哪个单元的身份 → 哪份方案」
  Future<bool> savePickingPlan(
      RenewTask task, List<UnitReplacement> replacements) async {
    // 位置→身份的翻译只能用**工作台手上那份单元**：`replacements` 是按
    // 界面上摆的顺序排的，拿盘上那份（可能已经被 Agent 加了单元）去对号，
    // 方案会安到别人身上。翻译完得到的是一份按 uid 索引的方案，往下写才
    // 不受位置影响——这一步是纯计算，留在 edit 之外
    final byUid = RenewTask.byUid(task.units ?? const <SemanticUnit>[],
        replacements);
    return _write(
      task,
      op: 'plans.apply',
      edit: (fresh) => TaskEdit(
        task: fresh.copyWith(replacementsByUid: byUid),
        before: {'units': _planFacts(fresh.replacementsByUid, fresh)},
        after: {'units': _planFacts(byUid, fresh)},
      ),
    );
  }

  /// 一份方案的判断依据：哪个单元挑了哪几条素材、那些素材是什么样的。
  ///
  /// 只记 id 的话，Agent 看到「人删了两条」也说不出他不要的是哪一类
  /// （素材的名字、画面描述、时长、烧没烧字、是哪家的品牌才是判据）。
  static List<Map<String, dynamic>> _planFacts(
      Map<String, UnitReplacement> byUid, RenewTask facts) {
    final materials = {for (final m in facts.pickedMaterials) m.id: m};
    Map<String, dynamic> material(int id) {
      final m = materials[id];
      return {
        'id': id,
        if (m != null) ...{
          'name': m.name,
          'sceneDescription': m.sceneDescription,
          'durationMs': m.durationMs,
          'burnedText': m.burnedText,
          'productBrand': m.productBrand,
        },
      };
    }

    return [
      for (final entry in byUid.entries)
        {
          'unitUid': entry.key,
          'mode': entry.value.mode.name,
          'materials': [
            for (final id in entry.value.wholeCandidateIds) material(id),
            for (final shot in entry.value.shotCandidateIds.entries)
              for (final id in shot.value)
                {'shot': shot.key, ...material(id)},
          ],
        },
    ];
  }

  /// 记下一次导出。**追加**而不是覆盖：项目会被反复导出，每一次都是一条
  /// 独立的记录（哪天、导了几条、成了几条、在哪个目录）
  Future<bool> addExportRecord(RenewTask task, ExportRecord record) async {
    return _write(
      task,
      op: 'export.run',
      edit: (fresh) => TaskEdit(
        // 追加到 fresh 的那份清单上：手上这份可能少了别人刚记的一次
        task: fresh.copyWith(exports: [...fresh.exports, record]),
        before: {'exportCount': fresh.exports.length},
        after: {
          'exportCount': fresh.exports.length + 1,
          'total': record.total,
          'succeeded': record.succeeded,
          'cancelled': record.cancelled,
          'outputDir': record.outputDir,
        },
      ),
    );
  }

  /// 已挑中素材的落地记录。和替换方案分开存：方案是「选了哪些 id」，
  /// 这里是「那些 id 到底是什么」——后者是为了让用户随时看得见自己选了什么，
  /// 和检索结果、翻到第几页、换没换项目组都无关。
  Future<bool> savePickedMaterials(
      RenewTask task, List<PickedMaterial> materials) async {
    return _write(
      task,
      op: 'materials.picked',
      edit: (fresh) {
        final was = {for (final m in fresh.pickedMaterials) m.id};
        final now = {for (final m in materials) m.id};
        return TaskEdit(
          task: fresh.copyWith(pickedMaterials: materials),
          before: {'count': fresh.pickedMaterials.length},
          after: {
            'count': materials.length,
            // **进来的和出去的都要摊开记，尤其出去的那一侧**：需求判据的
            // 原话就是「Agent 挑了四五个分镜，人删除了其中两个，Agent 要能
            // 只凭日志总结出人不想要的是哪个类型」——记的就是删除那一侧。
            // 只有 id 和名字，「哪个类型」无从谈起。素材对象就在 fresh 手上
            'added': [
              for (final m in materials)
                if (!was.contains(m.id)) _materialFacts(m),
            ],
            'removed': [
              for (final m in fresh.pickedMaterials)
                if (!now.contains(m.id)) _materialFacts(m),
            ],
          },
        );
      },
    );
  }

  /// 一条素材的判断依据。**「人不要的是哪一类」全在这五个字段里**：
  /// 画面是什么、多长、烧没烧别人的字、露的是哪家的品牌
  static Map<String, dynamic> _materialFacts(PickedMaterial m) => {
        'id': m.id,
        'name': m.name,
        'sceneDescription': m.sceneDescription,
        'durationMs': m.durationMs,
        'burnedText': m.burnedText,
        'productBrand': m.productBrand,
      };

  /// 存「保留素材原声」的全片打底设置。传进来的 [task] 已经带上新值了——
  /// 只把**这一个字段**搬到 fresh 上，别的一律不碰
  Future<bool> saveMaterialAudio(RenewTask task) async {
    final setting = task.materialAudio;
    return _write(
      task,
      op: 'audio.material',
      edit: (fresh) => TaskEdit(
        task: fresh.copyWith(materialAudio: setting),
        before: {
          'mode': fresh.materialAudio.mode.name,
          'volume': fresh.materialAudio.volume,
        },
        after: {'mode': setting.mode.name, 'volume': setting.volume},
      ),
    );
  }

  /// 存手改过的字幕轨。传进来的 [task] 已经带上新值了
  Future<bool> saveSubtitleTrack(RenewTask task) async {
    final track = task.subtitleTrack;
    return _write(
      task,
      op: 'subtitle.track',
      edit: (fresh) => TaskEdit(
        task: fresh.copyWith(subtitleTrack: track),
        before: {'edited': _subtitleFacts(fresh.subtitleTrack)},
        after: {'edited': _subtitleFacts(track)},
      ),
    );
  }

  /// 手改过的字幕：改了哪几镜、改成了什么字。
  ///
  /// 记文本而不是坑位数——「他把这一镜的字删空了」和「这一镜本来就没字」
  /// 在数字上长得一模一样
  static List<Map<String, dynamic>> _subtitleFacts(SubtitleTrack track) => [
        for (final slot in track.editedSlots)
          {
            'unitUid': slot.unitUid,
            'shot': slot.shotIndex,
            'lines': [
              for (final line in track.linesOf(slot) ?? const []) line.text,
            ],
          },
      ];

  /// 改这条任务用哪些标签组。
  ///
  /// 标签组本来只在新建向导里选一次；选漏了或选错了就再也改不了，那条任务
  /// 从此打不出标签、候选检索的标签主路径也就永远用不上。
  Future<bool> saveTagGroups(
    RenewTask task, {
    required List<TagGroupRef> unit,
    required List<TagGroupRef> shot,
    String? unitPrompt,
    String? shotPrompt,
    ProjectRef? project,
  }) async {
    return _write(
      task,
      op: 'task.tagGroups',
      edit: (fresh) => TaskEdit(
        task: fresh.copyWith(
          project: project,
          // 显式选了「不限项目」时要真的清掉，不能被 ?? 当成「没传」
          clearProject: project == null,
          unitTagGroups: unit,
          shotTagGroups: shot,
          unitTagPrompt: unitPrompt,
          shotTagPrompt: shotPrompt,
        ),
        before: {
          'project': fresh.project?.name,
          'unitTagGroups': [for (final g in fresh.unitTagGroups) g.name],
          'shotTagGroups': [for (final g in fresh.shotTagGroups) g.name],
          'unitTagPrompt': fresh.unitTagPrompt,
          'shotTagPrompt': fresh.shotTagPrompt,
        },
        after: {
          'project': project?.name,
          'unitTagGroups': [for (final g in unit) g.name],
          'shotTagGroups': [for (final g in shot) g.name],
          'unitTagPrompt': unitPrompt ?? fresh.unitTagPrompt,
          'shotTagPrompt': shotPrompt ?? fresh.shotTagPrompt,
        },
      ),
    );
  }

  /// 保存配乐方案。与切分、替换方案同一条「随手落库」通路。
  Future<bool> saveBgm(RenewTask task, BgmPlan bgm) async {
    return _write(
      task,
      op: 'bgm.set',
      edit: (fresh) => TaskEdit(
        task: fresh.copyWith(bgm: bgm),
        before: {'segments': _bgmFacts(fresh.bgm)},
        after: {'segments': _bgmFacts(bgm)},
      ),
    );
  }

  /// 配乐方案的判断依据：哪几个单元铺了哪几首、多大声
  static List<Map<String, dynamic>> _bgmFacts(BgmPlan bgm) => [
        for (final s in bgm.segments)
          {
            'startUnit': s.startUnit,
            'endUnit': s.endUnit,
            'materials': [
              for (final m in s.materials) {'id': m.id, 'name': m.name},
            ],
          },
      ];

  /// 记下这条任务自己的人声轨。
  ///
  /// 人声轨**归任务所有**，两条任务之间不共用（见 [PreparedCache]）：它被
  /// 别人删任务时一起清掉、或当初那次分离失败过，用户都能在工作台点
  /// 「重新分离」补一份，补完就落在这里
  Future<bool> saveVocals(RenewTask task, SeparatedAudio stems) async {
    return _write(
      task,
      op: 'audio.vocals',
      note: '人在工作台点了「重新分离」',
      edit: (fresh) => TaskEdit(
        task: fresh.copyWith(
          vocalsPath: stems.vocalsPath,
          backgroundPath: stems.backgroundPath,
        ),
        before: {
          'vocalsPath': fresh.vocalsPath,
          'backgroundPath': fresh.backgroundPath,
        },
        after: {
          'vocalsPath': stems.vocalsPath,
          'backgroundPath': stems.backgroundPath,
        },
      ),
    );
  }

  /// 保存换音色方案。与切分、替换方案、配乐同一条「随手落库」通路。
  Future<bool> saveVoices(RenewTask task, VoicePlan voices) async {
    return _write(
      task,
      op: 'voice.assign',
      edit: (fresh) => TaskEdit(
        task: fresh.copyWith(voices: voices),
        before: {'assignments': _voiceFacts(fresh.voices)},
        after: {'assignments': _voiceFacts(voices)},
      ),
    );
  }

  /// 换音色方案的判断依据：哪个单元换成了哪个音色（带音色名，不是光一个 id）
  static List<Map<String, dynamic>> _voiceFacts(VoicePlan voices) => [
        for (final a in voices.assignments)
          {'unitUid': a.unitUid, 'voice': a.voice.name, 'voiceId': a.voice.id},
      ];

  /// 工作台落库：保存编辑后的 units。
  ///
  /// 工作台里的每次改动都直接落库（防抖 800ms），不需要用户点「保存」或
  /// 「确认」——他改完就该当作已经存下了。状态不变：editing 一直到导出。
  ///
  /// **这一份 units 是人手上那份的整体**（拖边界、拆合镜头、改台词都在里面），
  /// 没有更细的粒度可拆；能做到的是只换 `units` 这一个字段，其余交给 fresh，
  /// 并把真正变了的那几个单元点名记下来、盖上「人改过」的戳。
  Future<bool> saveSegmentationDraft(
      RenewTask task, List<SemanticUnit> units) async {
    return _write(
      task,
      op: 'units.edit',
      edit: (fresh) {
        final before = fresh.units ?? const <SemanticUnit>[];
        // **除了来源戳之外什么都没变，就整笔不做**（不落盘、不记账）。
        //
        // 工作台那道「变了没有」的守卫用的是 `SemanticUnit` 的 `==`，而
        // `editedBy` 在里面：Agent 写一次、盖一次戳，这里就被叫醒一次，
        // 于是日志里多一笔**人名下的空改动**——Agent 读到「人改过这个
        // 单元」就可能绕开它，而人一根手指都没动（2026-09-18 真机复现）。
        //
        // 判据不能用下面那个 `changed` 为空：`_changedUnitFacts` 只比
        // 台词/起止/镜数/标签，人在单元内部拖一条镜头边界它一样是空的，
        // 拿它短路就成了静默丢改动
        if (!segmentationChanged(before, units)) {
          return TaskEdit.nothingChanged(fresh);
        }
        final changed = _changedUnitFacts(before, units);
        return TaskEdit(
          task: fresh.copyWith(units: units),
          before: {
            'unitCount': fresh.units?.length,
            'changed': [for (final c in changed) c.before],
          },
          after: {
            'unitCount': units.length,
            'changed': [for (final c in changed) c.after],
          },
          // 两道过滤，少一道都会让 `_reportMissedStamps` 稳定误报——
          // 那条告警存在的意义是「戳没盖上而日志照记」，让它在最常见的
          // 编辑动作上天天喊狼来了，真出事那次就没人信了：
          //
          // 1. **删掉的单元不盖**：戳长在单元对象上，对象都没了，盖无可盖。
          //    删一个单元、合并两个单元（合并＝删掉一个）是工作台最常见的动作
          // 2. **还没发身份的不盖**：uid 是空串（老存档、刚拆出来还没跑
          //    ensureUnitUids），点了名也认不出是哪一个
          stampUnits: [
            for (final c in changed)
              if (c.stillThere && isUnitUid(c.uid)) c.uid,
          ],
        );
      },
    );
  }

  /// 比出这一笔真正动了哪几个单元。
  ///
  /// `stillThere` = 改完之后这个单元还在不在。**被删掉的也算一次「改动」**
  /// （日志要记下人删了什么），但它盖不了戳——戳长在单元对象上，对象没了
  /// 就无处可盖，点名反而会被 `_reportMissedStamps` 报成「戳丢了」。
  ///
  /// **按 uid 配对，不按下标**：人可能删过、挪过单元，下标早就不是发起那一刻
  /// 那一套了。新加的单元（fresh 里没有）算「改动」，被删掉的也算。
  ///
  /// **两边都发齐了身份才按身份配对，否则退回按位置比**。老存档、刚
  /// `new` 出来的单元 uid 是空串，而编辑器收下它们时会补发一轮
  /// （`ensureUnitUids`）——于是「盘上那份没有 uid、手上这份有」是常态。
  /// 这时按 uid 配对会把每一个单元都认成「新加的」，人明明什么都没改，
  /// 却被结结实实盖上一圈「人改过」的戳（2026-09-18 真机测试当场抓到：
  /// 打开工作台什么都不动就返回，两个单元全被标成人改过的）。
  static List<_UnitChange> _changedUnitFacts(
      List<SemanticUnit> before, List<SemanticUnit> after) {
    Map<String, dynamic> facts(SemanticUnit u) => {
          'transcript': u.transcript,
          'startMs': u.startMs,
          'endMs': u.endMs,
          'shotCount': u.shots.length,
          'tags': u.tags,
        };
    bool same(SemanticUnit a, SemanticUnit b) =>
        const DeepCollectionEquality().equals(facts(a), facts(b));
    final changed = <_UnitChange>[];

    final byUid = before.every((u) => isUnitUid(u.uid)) &&
        after.every((u) => isUnitUid(u.uid));
    if (!byUid) {
      for (var i = 0; i < after.length; i++) {
        if (i >= before.length) {
          changed.add(_added(after[i].uid, facts(after[i])));
        } else if (!same(before[i], after[i])) {
          changed.add(_edited(after[i].uid, facts(before[i]), facts(after[i])));
        }
      }
      for (var i = after.length; i < before.length; i++) {
        changed.add(_removed(before[i].uid, facts(before[i])));
      }
      return changed;
    }

    final was = {for (final u in before) u.uid: u};
    final now = {for (final u in after) u.uid: u};
    for (final u in after) {
      final old = was[u.uid];
      if (old == null) {
        changed.add(_added(u.uid, facts(u)));
      } else if (!same(old, u)) {
        changed.add(_edited(u.uid, facts(old), facts(u)));
      }
    }
    for (final u in before) {
      if (!now.containsKey(u.uid)) {
        changed.add(_removed(u.uid, facts(u)));
      }
    }
    return changed;
  }

  /// **身份要记进日志的两侧，但绝不能进 `facts()`。**
  ///
  /// 记进日志：改动日志全仓按 `unitUid` 记名（`unit.*`、`blank.*`、
  /// `units.tag.*`、审片台的 `unit.tags`），而 `units.edit` 是**人那一侧
  /// 唯一的 op**——它不点名，需求②要的「哪些是人干的」就在最后一米断掉：
  /// Agent 知道人改过某个单元，却不知道是哪一个，而所有写命令按下标点名。
  ///
  /// 不进 `facts()`：那份 map 同时用来判「这个单元变没变」，而
  /// 「盘上那份还没发身份、手上这份已经发了」是常态（见 [_changedUnitFacts]
  /// 的文档）——uid 一旦参与比对，那种情况下每个单元都会被判成改过。
  ///
  /// 空串不写：老存档里没有身份的单元点了名也认不出是哪一个，
  /// 写个空串只会让人以为「发过但是空的」（和 `SemanticUnit.toJson` 同规矩）。
  /// 走仓库读出来的任务一律补发过身份，实际走不到这一支。
  static Map<String, dynamic> _named(String uid, Map<String, dynamic> facts) =>
      {if (isUnitUid(uid)) 'uid': uid, ...facts};

  static _UnitChange _added(String uid, Map<String, dynamic> after) => (
        uid: uid,
        before: _named(uid, {'present': false}),
        after: _named(uid, after),
        stillThere: true
      );

  static _UnitChange _edited(
          String uid, Map<String, dynamic> b, Map<String, dynamic> a) =>
      (
        uid: uid,
        before: _named(uid, b),
        after: _named(uid, a),
        stillThere: true
      );

  static _UnitChange _removed(String uid, Map<String, dynamic> before) => (
        uid: uid,
        before: _named(uid, before),
        after: _named(uid, {'present': false}),
        stillThere: false
      );

  /// 工作台那一批「随手落库」的共同形状：走唯一写入口、写完刷新列表。
  ///
  /// **返回「到底写没写成」**：任务在这一刻被删掉时返回 false
  /// （那是事实，不是失败——不重建它，也不把删掉的任务复活）。
  /// 调用方**必须把这个 false 说给人听**：画面上已经变了、盘上没变，
  /// 不说的话人以为改动留住了，关了窗才发现全没了。
  Future<bool> _write(
    RenewTask task, {
    required String op,
    String note = '',
    required TaskEdit Function(RenewTask fresh) edit,
  }) async {
    final updated = await _mutation(actorWorkbench)
        .apply(taskId: task.id, op: op, note: note, edit: edit);
    if (updated == null) {
      AppLog.warn('任务 ${task.id} 的「$op」没写成：这条任务已经被删了。');
      return false;
    }
    await _refreshAfterSave(updated);
    return true;
  }
}

final taskListProvider =
    AsyncNotifierProvider<TaskListController, List<RenewTask>>(
        TaskListController.new);


/// 启动时要直接打开的任务（来自 `ishkafel open <task>` 传的 `--task=`）。
///
/// null 表示照常进列表页。用完即弃：打开过一次就不该再自动跳，否则用户
/// 返回列表会被立刻弹回去
final initialTaskIdProvider = Provider<String?>((ref) => null);

