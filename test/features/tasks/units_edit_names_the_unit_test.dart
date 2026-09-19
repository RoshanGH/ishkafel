import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/task_log.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/settings/settings_providers.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';

/// **人那一侧的那一笔，也要说得出动的是哪一个单元。**
///
/// 改动日志全仓按 `unitUid` 记名：`unit.*` 十一处、`blank.*` 两处、审片台的
/// `unit.tags`、`units.tag.*` 的 `taggedUnits` —— 而 `task --json` 现在也报
/// `uid` 了，所以 Agent 读完日志能把那个 uid 对回一个下标去操作。
///
/// 唯独 `units.edit`（**人在工作台改切分，人那一侧唯一的 op**）一个 uid 都
/// 没有：`changed` 里只有台词/起止/镜数/标签。于是需求②要的「哪些是人干的」
/// 在最后一米断掉——Agent 知道「人改过某个单元」，却不知道是哪一个。
///
/// 而手册白纸黑字写着「`changed` 按 uid 列出真正变了的那几个单元」。
void main() {
  late _Repo repo;
  late Directory dataDir;
  late ProviderContainer container;

  SemanticUnit unit(String uid, {required int at, String transcript = '原句'}) =>
      SemanticUnit(
        uid: uid,
        index: at,
        startMs: at * 1000,
        endMs: (at + 1) * 1000,
        transcript: transcript,
        shots: [Shot(startMs: at * 1000, endMs: (at + 1) * 1000)],
      );

  RenewTask taskWith(List<SemanticUnit> u) => RenewTask(
        id: 'wb1',
        name: '滴露',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 18),
        updatedAt: DateTime.utc(2026, 9, 18),
        units: u,
      );

  List<SemanticUnit> two() => [
        unit('kaaaaaaaaaaa', at: 0),
        unit('kbbbbbbbbbbb', at: 1),
      ];

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('ishkafel_unitsedit_');
    repo = _Repo();
    container = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      dataDirProvider.overrideWithValue(dataDir),
    ]);
    addTearDown(container.dispose);
  });
  tearDown(() async => dataDir.delete(recursive: true));

  Future<void> save(List<SemanticUnit> u) async {
    await container.read(taskListProvider.future);
    await container
        .read(taskListProvider.notifier)
        .saveSegmentationDraft(taskWith(u), u);
  }

  List<Map<String, dynamic>> changedOf(TaskLogEntry e, String side) => [
        for (final c in ((side == 'before' ? e.before : e.after)!['changed']
            as List))
          Map<String, dynamic>.from(c as Map),
      ];

  TaskLogEntry lastEntry() =>
      TaskLogFile(dataDir: dataDir, taskId: 'wb1').read(limit: 1 << 20).last;

  test('改了一个单元：changed 的两侧都点名它的 uid', () async {
    await repo.save(taskWith(two()));

    await save([
      two().first,
      unit('kbbbbbbbbbbb', at: 1, transcript: '人改过的句子'),
    ]);

    final e = lastEntry();
    expect(e.op, 'units.edit');
    expect(changedOf(e, 'before').single['uid'], 'kbbbbbbbbbbb',
        reason: '「原来是什么」那一侧也要说得出是哪一个单元');
    expect(changedOf(e, 'after').single['uid'], 'kbbbbbbbbbbb',
        reason: '手册写着「changed 按 uid 列出真正变了的那几个单元」');
  });

  test('日志里那个 uid，能原样对回 task --json 里的 uid', () async {
    await repo.save(taskWith(two()));
    await save([
      two().first,
      unit('kbbbbbbbbbbb', at: 1, transcript: '人改过的句子'),
    ]);

    final uid = changedOf(lastEntry(), 'after').single['uid'];
    final reported = [
      for (final u in (taskToJson((await repo.findById('wb1'))!)['units']
          as List))
        (u as Map)['uid'],
    ];
    expect(reported, contains(uid),
        reason: '对不回去的身份等于没给——所有写命令都按下标点名');
  });

  test('删掉一个单元：也要点名删的是哪一个（戳盖不上，但账要记清）', () async {
    await repo.save(taskWith(two()));

    await save([two().first]);

    final e = lastEntry();
    expect(changedOf(e, 'before').single['uid'], 'kbbbbbbbbbbb');
    expect(changedOf(e, 'after').single['uid'], 'kbbbbbbbbbbb',
        reason: '「这个单元没了」那一侧同样要说得出是哪一个');
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
