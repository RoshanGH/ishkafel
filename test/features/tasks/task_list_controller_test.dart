import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/analysis/silence_detector.dart';
import 'package:ishkafel/core/ffmpeg/ffprobe_service.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/import_flow/import_service.dart';
import 'package:ishkafel/features/tasks/task_artifact_cleaner.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';

/// 假 ASR/切分：不会被调用（_FakePipeline 覆写 analyze，不走真实管线）
class _NoopAsr implements AsrProvider {
  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async => const [];
}

class _NoopSplitter implements SemanticSplitter {
  @override
  Future<List<UnitDraft>> split(List<AsrSentence> sentences) async => const [];
}

/// 假分析管线：跳过真实音视频/AI 调用，直接模拟分析结果落库（或失败）
class _FakePipeline extends AnalysisPipeline {
  final TaskRepository repo;
  final bool shouldFail;
  final String failMessage;
  int analyzeCallCount = 0;

  _FakePipeline({
    required this.repo,
    this.shouldFail = false,
    this.failMessage = '分析失败（模拟）',
  }) : super(
          audio: AudioExtractor(run: (_, _) async => ProcessResult(1, 0, '', '')),
          silence: const SilenceDetector(),
          scenes: SceneDetector(run: (_, _) async => ProcessResult(1, 0, '', '')),
          asr: _NoopAsr(),
          splitter: _NoopSplitter(),
          builder: const SegmentationBuilder(snapper: BoundarySnapper()),
          repository: repo,
          workDir: Directory.systemTemp,
        );

  @override
  Future<RenewTask> analyze(RenewTask task) async {
    analyzeCallCount++;
    if (shouldFail) throw StateError(failMessage);
    final updated =
        task.copyWith(status: RenewTaskStatus.awaitingCut, updatedAt: DateTime.now());
    await repo.save(updated);
    return updated;
  }
}

/// 记录被清理的任务 id，验证删除确实连带清理中间产物
class _RecordingCleaner implements TaskArtifactCleaner {
  final List<String> cleaned;
  _RecordingCleaner(this.cleaned);
  @override
  Future<void> cleanup(String taskId) async => cleaned.add(taskId);
}

/// 清理失败的假实现：不应阻断任务删除
class _ThrowingCleaner implements TaskArtifactCleaner {
  @override
  Future<void> cleanup(String taskId) async =>
      throw const FileSystemException('磁盘只读');
}

/// 内存假实现，避免测试碰文件系统（仿照 task_list_page_test.dart 的做法）
class InMemoryTaskRepository implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async {
    final list = _store.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}

/// 记录 findAll 调用次数的假仓库：用于证明「保存一条任务不再全量重读」
class _CountingRepository extends InMemoryTaskRepository {
  int findAllCallCount = 0;

  @override
  Future<List<RenewTask>> findAll() async {
    findAllCallCount++;
    return super.findAll();
  }
}

RenewTask makeExternalTask(String id, String name, DateTime updatedAt) =>
    RenewTask(
      id: id,
      name: name,
      sourcePath: '/v/$id.mp4',
      status: RenewTaskStatus.analyzing,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );

/// ffprobe 假返回，结构与 import_service_test.dart 保持一致
const probeJson = {
  'streams': [
    {
      'codec_type': 'video',
      'width': 1080,
      'height': 1920,
      'r_frame_rate': '30/1',
    },
  ],
  'format': {'duration': '10.0', 'size': '100'},
};

void main() {
  late InMemoryTaskRepository repo;
  late ImportService importService;
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir =
        await Directory.systemTemp.createTemp('ishkafel_controller_test_');
    repo = InMemoryTaskRepository();
    importService = ImportService(
      repository: repo,
      // 假 ffprobe/ffmpeg ProcessRunner，避免测试依赖真实二进制
      ffprobe: FfprobeService(
          run: (_, _) async => ProcessResult(1, 0, jsonEncode(probeJson), '')),
      thumbnails:
          ThumbnailService(run: (_, _) async => ProcessResult(1, 0, '', '')),
      coversDir: Directory('${tempDir.path}/covers'),
      idGenerator: () => 'new-id',
      clock: () => DateTime.utc(2026, 7, 29, 12),
    );
    container = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      importServiceProvider.overrideWithValue(importService),
    ]);
    addTearDown(container.dispose);
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('importFile 导入后新任务出现在任务列表中', () async {
    // 先等 build() 完成，建立初始（空）状态
    await container.read(taskListProvider.future);

    await container
        .read(taskListProvider.notifier)
        .importFile('/videos/新片.mp4');

    final state = container.read(taskListProvider);
    expect(state, isA<AsyncData<List<RenewTask>>>());
    final tasks = state.value!;
    expect(tasks.map((t) => t.id), contains('new-id'));
    expect(tasks.firstWhere((t) => t.id == 'new-id').name, '新片');
  });

  test('reload 重新从仓库拉取内容', () async {
    await container.read(taskListProvider.future);
    expect(container.read(taskListProvider).value, isEmpty);

    // 绕过 controller 直接写仓库，模拟状态之外发生的变化
    await repo.save(makeExternalTask('ext', '外部任务', DateTime.utc(2026, 7, 29)));
    // 此时 controller 持有的 state 还未刷新
    expect(container.read(taskListProvider).value, isEmpty);

    await container.read(taskListProvider.notifier).reload();

    final tasks = container.read(taskListProvider).value!;
    expect(tasks.map((t) => t.id), contains('ext'));
  });

  test('importFile 后自动触发分析并刷新为 awaitingCut', () async {
    final pipelineContainer = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      importServiceProvider.overrideWithValue(importService),
      analysisPipelineProvider
          .overrideWithValue(_FakePipeline(repo: repo)),
    ]);
    addTearDown(pipelineContainer.dispose);

    await pipelineContainer.read(taskListProvider.future);
    await pipelineContainer
        .read(taskListProvider.notifier)
        .importFile('/videos/新片.mp4');

    // importFile 本身只等落库+首次刷新（此时任务仍是 analyzing），
    // 后台分析异步完成后再刷新一次
    await pumpEventQueue();

    final tasks = pipelineContainer.read(taskListProvider).value!;
    final task = tasks.firstWhere((t) => t.id == 'new-id');
    expect(task.status, RenewTaskStatus.awaitingCut);
  });

  test('分析失败时任务保持 analyzing、落库 analysisError 且不崩溃', () async {
    final pipelineContainer = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      importServiceProvider.overrideWithValue(importService),
      analysisPipelineProvider
          .overrideWithValue(_FakePipeline(repo: repo, shouldFail: true)),
    ]);
    addTearDown(pipelineContainer.dispose);

    await pipelineContainer.read(taskListProvider.future);
    await pipelineContainer
        .read(taskListProvider.notifier)
        .importFile('/videos/新片.mp4');

    await pumpEventQueue();

    final tasks = pipelineContainer.read(taskListProvider).value!;
    final task = tasks.firstWhere((t) => t.id == 'new-id');
    expect(task.status, RenewTaskStatus.analyzing);
    expect(task.analysisError, contains('分析失败（模拟）'));

    // 仓库中同样落库，保证重启后仍能读到失败原因
    final persisted = await repo.findById('new-id');
    expect(persisted!.analysisError, isNotNull);
  });

  test('分析失败信息落库前按 300 字截断，避免超长堆栈污染 JSON', () async {
    final longMessage = '错' * 500;
    final pipelineContainer = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      importServiceProvider.overrideWithValue(importService),
      analysisPipelineProvider.overrideWithValue(
          _FakePipeline(repo: repo, shouldFail: true, failMessage: longMessage)),
    ]);
    addTearDown(pipelineContainer.dispose);

    await pipelineContainer.read(taskListProvider.future);
    await pipelineContainer
        .read(taskListProvider.notifier)
        .importFile('/videos/新片.mp4');

    await pumpEventQueue();

    final tasks = pipelineContainer.read(taskListProvider).value!;
    final task = tasks.firstWhere((t) => t.id == 'new-id');
    expect(task.analysisError!.length, lessThanOrEqualTo(300));
  });

  test('分析失败信息截断码点安全，不切断 UTF-16 代理对（含 emoji 的错误信息）', () async {
    // 落库前的原始异常经 StateError.toString() 会加上「Bad state: 」前缀，
    // 这里按前缀长度动态推算 ASCII 填充数，使「前缀 + ASCII」恰好占满 299 个
    // UTF-16 code unit——这样后面第一个 emoji（占 2 个 code unit）恰好横跨
    // 第 300 个截断边界，若按 code unit 朴素 substring(0, 300) 截断会切在
    // 代理对中间，留下落单的高位 surrogate。
    final prefixLength = StateError('').toString().length;
    final asciiCount = 299 - prefixLength;
    final longMessage = '${'a' * asciiCount}${'😀' * 10}';
    final pipelineContainer = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      importServiceProvider.overrideWithValue(importService),
      analysisPipelineProvider.overrideWithValue(
          _FakePipeline(repo: repo, shouldFail: true, failMessage: longMessage)),
    ]);
    addTearDown(pipelineContainer.dispose);

    await pipelineContainer.read(taskListProvider.future);
    await pipelineContainer
        .read(taskListProvider.notifier)
        .importFile('/videos/新片.mp4');
    await pumpEventQueue();

    final tasks = pipelineContainer.read(taskListProvider).value!;
    final task = tasks.firstWhere((t) => t.id == 'new-id');
    final result = task.analysisError!;

    // 不应以落单的高位代理（high surrogate, U+D800-U+DBFF）结尾
    expect(result.codeUnits.last, isNot(inInclusiveRange(0xD800, 0xDBFF)));
    // UTF-8 编解码往返一致（无落单 surrogate 才能安全编解码）
    expect(utf8.decode(utf8.encode(result)), result);
    // JSON 落库/读取往返一致
    final decoded = RenewTask.fromJson(jsonDecode(jsonEncode(task.toJson())));
    expect(decoded.analysisError, result);
  });

  group('AI 未配置：导入后不能静默卡死在「分析中」', () {
    test('管线不可用时导入立即落成失败态并带人话原因', () async {
      await container.read(taskListProvider.future);

      await container
          .read(taskListProvider.notifier)
          .importFile('/videos/新片.mp4');

      final task = container
          .read(taskListProvider)
          .value!
          .firstWhere((t) => t.id == 'new-id');
      expect(task.analysisError, isNotNull);
      expect(task.analysisError, contains('AI'));
      expect((await repo.findById('new-id'))!.analysisError, isNotNull,
          reason: '必须落库，重启后仍能看到原因并重试');
    });

    test('并发守卫命中时 retryAnalysis 返回 alreadyRunning', () async {
      final task = makeExternalTask('busy', '进行中', DateTime.utc(2026, 7, 29));
      await repo.save(task);
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(_FakePipeline(repo: repo)),
      ]);
      addTearDown(pipelineContainer.dispose);
      await pipelineContainer.read(taskListProvider.future);
      final notifier = pipelineContainer.read(taskListProvider.notifier);

      final first = notifier.retryAnalysis(task);
      final second = notifier.retryAnalysis(task);
      final outcomes = await Future.wait([first, second]);
      await pumpEventQueue();

      expect(outcomes, [RetryOutcome.started, RetryOutcome.alreadyRunning]);
    });
  });

  group('启动装载：僵死的「分析中」任务恢复', () {
    RenewTask makeAnalyzing(String id, {String? analysisError}) => RenewTask(
          id: id,
          name: '任务$id',
          sourcePath: '/v/$id.mp4',
          status: RenewTaskStatus.analyzing,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          analysisError: analysisError,
        );

    test('分析中途退出 app 的任务被标记为「已中断」并落库，从而可走重试路径', () async {
      await repo.save(makeAnalyzing('stalled'));

      final tasks = await container.read(taskListProvider.future);

      final task = tasks.firstWhere((t) => t.id == 'stalled');
      expect(task.status, RenewTaskStatus.analyzing);
      expect(task.analysisError, isNotNull);
      expect(task.analysisError, contains('中断'));
      expect((await repo.findById('stalled'))!.analysisError, isNotNull,
          reason: '必须落库，否则重启后仍然卡死');
    });

    test('已带失败原因的任务不被覆盖', () async {
      await repo.save(makeAnalyzing('failed', analysisError: '网络连接超时'));

      final tasks = await container.read(taskListProvider.future);

      expect(tasks.firstWhere((t) => t.id == 'failed').analysisError, '网络连接超时');
    });

    test('非「分析中」状态的任务不受影响', () async {
      await repo.save(makeAnalyzing('done').copyWith(
          status: RenewTaskStatus.awaitingCut, units: const []));

      final tasks = await container.read(taskListProvider.future);

      expect(tasks.firstWhere((t) => t.id == 'done').analysisError, isNull);
    });

    test('本次运行中正在分析的任务不会被 reload 误标为中断', () async {
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(_FakePipeline(repo: repo)),
      ]);
      addTearDown(pipelineContainer.dispose);

      await pipelineContainer.read(taskListProvider.future);
      await pipelineContainer
          .read(taskListProvider.notifier)
          .importFile('/videos/新片.mp4');
      await pumpEventQueue();

      final task = pipelineContainer
          .read(taskListProvider)
          .value!
          .firstWhere((t) => t.id == 'new-id');
      expect(task.analysisError, isNull);
    });
  });

  group('删除 / 重命名', () {
    RenewTask makeTask(String id) => RenewTask(
          id: id,
          name: '任务$id',
          sourcePath: '/v/$id.mp4',
          status: RenewTaskStatus.awaitingCut,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          units: const [],
        );

    test('deleteTask 从仓库移除并连带清理中间产物', () async {
      final cleaned = <String>[];
      await repo.save(makeTask('d1'));
      final deleteContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        taskArtifactCleanerProvider.overrideWithValue(
            _RecordingCleaner(cleaned)),
      ]);
      addTearDown(deleteContainer.dispose);

      await deleteContainer.read(taskListProvider.future);
      await deleteContainer
          .read(taskListProvider.notifier)
          .deleteTask(makeTask('d1'));

      expect(await repo.findById('d1'), isNull);
      expect(cleaned, ['d1']);
      expect(deleteContainer.read(taskListProvider).value, isEmpty);
    });

    test('产物清理失败不阻断删除', () async {
      await repo.save(makeTask('d2'));
      final deleteContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        taskArtifactCleanerProvider.overrideWithValue(_ThrowingCleaner()),
      ]);
      addTearDown(deleteContainer.dispose);

      await deleteContainer.read(taskListProvider.future);
      await deleteContainer
          .read(taskListProvider.notifier)
          .deleteTask(makeTask('d2'));

      expect(await repo.findById('d2'), isNull);
    });

    test('renameTask 保存新名称并刷新列表', () async {
      await repo.save(makeTask('r1'));
      await container.read(taskListProvider.future);

      await container
          .read(taskListProvider.notifier)
          .renameTask(makeTask('r1'), '  滴露_植源喷雾  ');

      final saved = await repo.findById('r1');
      expect(saved!.name, '滴露_植源喷雾', reason: '首尾空白应被去除');
      expect(container.read(taskListProvider).value!.single.name, '滴露_植源喷雾');
    });

    test('renameTask 空名称被拒绝，原名保留', () async {
      await repo.save(makeTask('r2'));
      await container.read(taskListProvider.future);

      await container.read(taskListProvider.notifier).renameTask(
            makeTask('r2'),
            '   ',
          );

      expect((await repo.findById('r2'))!.name, '任务r2');
    });
  });

  group('retryAnalysis', () {
    RenewTask makeFailedTask() => RenewTask(
          id: 'fail-1',
          name: '失败任务',
          sourcePath: '/v/fail-1.mp4',
          status: RenewTaskStatus.analyzing,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          analysisError: '分析失败（模拟）',
        );

    test('retryAnalysis 清空错误、重跑假管线成功后进入 awaitingCut', () async {
      final task = makeFailedTask();
      await repo.save(task);

      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(_FakePipeline(repo: repo)),
      ]);
      addTearDown(pipelineContainer.dispose);

      await pipelineContainer.read(taskListProvider.future);
      await pipelineContainer.read(taskListProvider.notifier).retryAnalysis(task);
      await pumpEventQueue();

      final tasks = pipelineContainer.read(taskListProvider).value!;
      final updated = tasks.firstWhere((t) => t.id == 'fail-1');
      expect(updated.status, RenewTaskStatus.awaitingCut);
      expect(updated.analysisError, isNull);
    });

    test('pipeline 未配置时 retryAnalysis 返回 pipelineUnavailable 并写入人话原因', () async {
      final task = makeFailedTask();
      await repo.save(task);
      await container.read(taskListProvider.future);

      final outcome =
          await container.read(taskListProvider.notifier).retryAnalysis(task);

      expect(outcome, RetryOutcome.pipelineUnavailable);
      final persisted = await repo.findById('fail-1');
      expect(persisted!.analysisError, contains('AI'));
      expect(persisted.analysisError, isNot(contains('Exception')));
      expect(persisted.status, RenewTaskStatus.analyzing);
    });

    test('pipeline 可用时 retryAnalysis 返回 started', () async {
      final task = makeFailedTask();
      await repo.save(task);
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(_FakePipeline(repo: repo)),
      ]);
      addTearDown(pipelineContainer.dispose);
      await pipelineContainer.read(taskListProvider.future);

      final outcome = await pipelineContainer
          .read(taskListProvider.notifier)
          .retryAnalysis(task);
      await pumpEventQueue();

      expect(outcome, RetryOutcome.started);
    });

    test('并发守卫：连续两次触发 retryAnalysis 同一任务，假管线 analyze 只执行一次', () async {
      final task = makeFailedTask();
      await repo.save(task);

      final pipeline = _FakePipeline(repo: repo);
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(pipeline),
      ]);
      addTearDown(pipelineContainer.dispose);

      await pipelineContainer.read(taskListProvider.future);
      final notifier = pipelineContainer.read(taskListProvider.notifier);

      // 模拟用户快速连点：不等待第一次调用完成即触发第二次
      final first = notifier.retryAnalysis(task);
      final second = notifier.retryAnalysis(task);
      await Future.wait([first, second]);
      await pumpEventQueue();

      expect(pipeline.analyzeCallCount, 1);

      final updated = pipelineContainer.read(taskListProvider).value!
          .firstWhere((t) => t.id == 'fail-1');
      expect(updated.status, RenewTaskStatus.awaitingCut);
    });
  });

  group('confirmSegmentation / saveSegmentationDraft', () {
    List<SemanticUnit> makeUnits() => [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 1000,
            transcript: '编辑后的台词',
            shots: const [Shot(startMs: 0, endMs: 1000)],
          ),
        ];

    RenewTask makeAwaitingCutTask() => RenewTask(
          id: 'cut-1',
          name: '待切分任务',
          sourcePath: '/v/cut-1.mp4',
          status: RenewTaskStatus.awaitingCut,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          units: const [],
        );

    test('confirmSegmentation 保存编辑后的 units 并流转为 picking', () async {
      final task = makeAwaitingCutTask();
      await repo.save(task);
      await container.read(taskListProvider.future);

      final units = makeUnits();
      await container
          .read(taskListProvider.notifier)
          .confirmSegmentation(task, units);

      final saved = await repo.findById('cut-1');
      expect(saved!.status, RenewTaskStatus.picking);
      expect(saved.units, units);

      final tasks = container.read(taskListProvider).value!;
      expect(tasks.firstWhere((t) => t.id == 'cut-1').status,
          RenewTaskStatus.picking);
    });

    test('saveSegmentationDraft 只保存 units 不改变状态', () async {
      final task = makeAwaitingCutTask();
      await repo.save(task);
      await container.read(taskListProvider.future);

      final units = makeUnits();
      await container
          .read(taskListProvider.notifier)
          .saveSegmentationDraft(task, units);

      final saved = await repo.findById('cut-1');
      expect(saved!.status, RenewTaskStatus.awaitingCut);
      expect(saved.units, units);
    });
  });

  group('保存后局部更新（不再全量重读所有任务 JSON）', () {
    late _CountingRepository counting;
    late ProviderContainer localContainer;

    RenewTask makeStored(String id, DateTime updatedAt) => RenewTask(
          id: id,
          name: '任务$id',
          sourcePath: '/v/$id.mp4',
          status: RenewTaskStatus.awaitingCut,
          createdAt: DateTime.utc(2026, 7, 1),
          updatedAt: updatedAt,
          units: const [],
        );

    List<SemanticUnit> makeUnits() => const [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 1000,
            transcript: '第一句',
            shots: [Shot(startMs: 0, endMs: 1000)],
          ),
        ];

    setUp(() async {
      counting = _CountingRepository();
      // 三条任务，updatedAt 依次递增（列表按 updatedAt 倒序：c、b、a）
      await counting.save(makeStored('a', DateTime.utc(2026, 7, 20)));
      await counting.save(makeStored('b', DateTime.utc(2026, 7, 21)));
      await counting.save(makeStored('c', DateTime.utc(2026, 7, 22)));
      localContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(counting),
        importServiceProvider.overrideWithValue(importService),
      ]);
      addTearDown(localContainer.dispose);
      await localContainer.read(taskListProvider.future);
    });

    test('confirmSegmentation 不触发 findAll，且列表里那一条已更新', () async {
      final before = counting.findAllCallCount;

      await localContainer
          .read(taskListProvider.notifier)
          .confirmSegmentation(makeStored('a', DateTime.utc(2026, 7, 20)),
              makeUnits());

      expect(counting.findAllCallCount, before,
          reason: '保存一条任务不应再遍历目录全量解码所有任务 JSON');
      final tasks = localContainer.read(taskListProvider).value!;
      expect(tasks.length, 3);
      final updated = tasks.firstWhere((t) => t.id == 'a');
      expect(updated.status, RenewTaskStatus.picking);
      expect(updated.units, makeUnits());
    });

    test('saveSegmentationDraft 不触发 findAll，且列表里那一条已更新', () async {
      final before = counting.findAllCallCount;

      await localContainer
          .read(taskListProvider.notifier)
          .saveSegmentationDraft(
              makeStored('b', DateTime.utc(2026, 7, 21)), makeUnits());

      expect(counting.findAllCallCount, before);
      final tasks = localContainer.read(taskListProvider).value!;
      expect(tasks.firstWhere((t) => t.id == 'b').units, makeUnits());
      expect(tasks.firstWhere((t) => t.id == 'b').status,
          RenewTaskStatus.awaitingCut);
    });

    test('局部更新后列表排序与全量重读一致（按 updatedAt 倒序）', () async {
      expect(localContainer.read(taskListProvider).value!.map((t) => t.id),
          ['c', 'b', 'a']);

      // 更新最旧的一条：updatedAt 变成 now，应排到最前
      await localContainer
          .read(taskListProvider.notifier)
          .saveSegmentationDraft(
              makeStored('a', DateTime.utc(2026, 7, 20)), makeUnits());

      final localOrder =
          localContainer.read(taskListProvider).value!.map((t) => t.id).toList();
      expect(localOrder, ['a', 'c', 'b']);

      // 与真正重读一次的结果逐条对齐，证明排序口径没有分叉
      await localContainer.read(taskListProvider.notifier).reload();
      expect(
          localContainer.read(taskListProvider).value!.map((t) => t.id).toList(),
          localOrder);
    });

    test('renameTask 同样局部更新，不全量重读', () async {
      final before = counting.findAllCallCount;

      await localContainer
          .read(taskListProvider.notifier)
          .renameTask(makeStored('c', DateTime.utc(2026, 7, 22)), '新名字');

      expect(counting.findAllCallCount, before);
      expect(localContainer.read(taskListProvider).value!
          .firstWhere((t) => t.id == 'c').name, '新名字');
    });

    test('deleteTask 局部移除那一条，不全量重读', () async {
      final before = counting.findAllCallCount;

      await localContainer
          .read(taskListProvider.notifier)
          .deleteTask(makeStored('b', DateTime.utc(2026, 7, 21)));

      expect(counting.findAllCallCount, before);
      expect(localContainer.read(taskListProvider).value!.map((t) => t.id),
          ['c', 'a']);
    });
  });
}
