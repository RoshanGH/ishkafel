import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/edit_stamp.dart';
import 'package:ishkafel/core/storage/task_log.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/settings/settings_providers.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';

/// **Agent 每写一次，日志就多一笔记在「人」头上的空改动。**
///
/// 真机受控复现（正式包、工作台开着那条任务）：Agent 写之前 4 条、
/// 写之后 **6 条**——预期 +1，实际 +2，多出来的那一笔是
/// `人 units.edit`，`changed: [] → []`，而人一根手指都没动。
///
/// 根因是跨任务交互：`editedBy` 进了 `SemanticUnit.operator ==`（它确实
/// 是数据的一部分）→ Agent 写完盖戳 → 工作台那道
/// `ListEquality().equals(_savedUnits!, units)` 判「变了」→ 落一次盘 →
/// 而 `_changedUnitFacts` 比对发现什么都没变 → 记一笔空的「人改过」。
///
/// 后果正中要害：Agent 查日志看到「人在 18:06 改过这个单元」，于是可能
/// 绕开它——**而人什么都没做**。这和 Task 9 在编导台修掉的是同一个形状
/// （「写一份没有任何改动的 doc + 记一笔假的 human 日志」）。
void main() {
  late _Repo repo;
  late Directory dataDir;
  late ProviderContainer container;

  List<SemanticUnit> units({
    List<String> tags = const ['促单'],
    int shotSplitMs = 0,
    EditStamp? stamp,
  }) =>
      [
        SemanticUnit(
          uid: 'kzzzzzzzzzzz',
          index: 0,
          startMs: 0,
          endMs: 2000,
          transcript: '第一句',
          tags: tags,
          editedBy: stamp,
          shots: shotSplitMs == 0
              ? const [Shot(startMs: 0, endMs: 2000)]
              : [
                  Shot(startMs: 0, endMs: shotSplitMs),
                  Shot(startMs: shotSplitMs, endMs: 2000),
                ],
        ),
      ];

  RenewTask taskWith(List<SemanticUnit> u) => RenewTask(
        id: 'wb1',
        name: '滴露',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 18),
        updatedAt: DateTime.utc(2026, 9, 18),
        units: u,
      );

  int logCount() =>
      TaskLogFile(dataDir: dataDir, taskId: 'wb1').read(limit: 1 << 20).length;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('ishkafel_emptylog_');
    repo = _Repo();
    container = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      dataDirProvider.overrideWithValue(dataDir),
    ]);
    addTearDown(container.dispose);
  });
  tearDown(() async => dataDir.delete(recursive: true));

  Future<bool> save(List<SemanticUnit> u) async {
    await container.read(taskListProvider.future);
    return container
        .read(taskListProvider.notifier)
        .saveSegmentationDraft(taskWith(u), u);
  }

  test('Agent 刚盖过戳、人什么都没改：不落盘、不记账', () async {
    // 盘上这一份是 Agent 刚写完的：内容没变，但多了一个来源戳
    final stamped = units(stamp: EditStamp(by: ActorKind.agent, at: DateTime.utc(2026, 9, 18, 18, 6)));
    await repo.save(taskWith(stamped));

    // 工作台手上那一份是它进门时读到的：一模一样，只是没有那个戳
    final ok = await save(units());

    expect(ok, isTrue, reason: '任务还在，这不是一次失败');
    expect(logCount(), 0,
        reason: '人一根手指都没动，日志里不许出现一笔他名下的改动——'
            'Agent 会据此绕开这个单元');
    final saved = await repo.findById('wb1');
    expect(saved!.units!.single.editedBy, stamped.single.editedBy,
        reason: 'Agent 的戳不许被这一次空写盖掉');
    expect(saved.updatedAt, DateTime.utc(2026, 9, 18),
        reason: '没改就不该推 updatedAt——那是 TaskMutation 的版本令牌');
  });

  test('真改了标签：照常落盘、照常记账（短路不许把正事一起短掉）', () async {
    await repo.save(taskWith(units()));

    final ok = await save(units(tags: const ['促单', '痛点']));

    expect(ok, isTrue);
    expect(logCount(), 1);
    final saved = await repo.findById('wb1');
    expect(saved!.units!.single.tags, ['促单', '痛点']);
    expect(saved.units!.single.editedBy!.by, ActorKind.human,
        reason: '人真改了就该盖人的戳');
  });

  test('只在单元内部拆了一镜：台词起止镜数标签全没变，但必须落盘', () async {
    // **这条盯的是短路的判据本身**：`changed` 为空不等于没改动——
    // `_changedUnitFacts` 只比台词/起止/镜数/标签，拿它当短路条件，
    // 人在单元内部拖一条镜头边界就会被静默丢掉
    await repo.save(taskWith(units(shotSplitMs: 500)));

    final ok = await save(units(shotSplitMs: 800));

    expect(ok, isTrue);
    final saved = await repo.findById('wb1');
    expect(saved!.units!.single.shots.first.endMs, 800,
        reason: '这是人真的拖过一条镜头边界，丢了就是数据丢失');
  });
}

class _Repo implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async => _store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}
