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

    test('retryAnalysis 在 pipeline 未配置时直接返回，不修改任务', () async {
      final task = makeFailedTask();
      await repo.save(task);
      await container.read(taskListProvider.future);

      await container.read(taskListProvider.notifier).retryAnalysis(task);

      final persisted = await repo.findById('fail-1');
      expect(persisted!.analysisError, '分析失败（模拟）');
      expect(persisted.status, RenewTaskStatus.analyzing);
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
}
