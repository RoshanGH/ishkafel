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

  _FakePipeline({required this.repo, this.shouldFail = false})
      : super(
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
    if (shouldFail) throw StateError('分析失败（模拟）');
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

  test('分析失败时任务保持 analyzing 且不崩溃', () async {
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
  });
}
