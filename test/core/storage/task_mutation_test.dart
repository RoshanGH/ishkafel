import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/log/app_log.dart';
import 'package:ishkafel/core/storage/edit_stamp.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/core/storage/task_log.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/task_mutation.dart';

import '../../support/seed_task.dart';

/// 锁删掉之后，同一条任务真的会有两个写入方。这个类是那时候唯一不让改动
/// 互相抹掉、也不让日志记成假账的东西。
void main() {
  late Directory dataDir;
  late FileTaskRepository repo;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('ishkafel_mut');
    repo = FileTaskRepository(dataDir);
  });
  tearDown(() => dataDir.deleteSync(recursive: true));

  TaskMutation agentMutation() => TaskMutation(
      repo: repo, dataDir: dataDir, by: ActorKind.agent, actor: 'Agent');

  test('交给 edit 的是刚从盘上重读的那份，不是调用方手里的旧快照', () async {
    final stale = await seedTask(dataDir, name: '原名');
    // 别人改了名字（模拟人在 Agent 思考的那 30 秒里动了手）
    await repo.save((await repo.findById(stale.id))!.copyWith(name: '人改过的名字'));

    late String sawName;
    await agentMutation().apply(
      taskId: stale.id,
      op: 'task.touch',
      edit: (fresh) {
        sawName = fresh.name;           // ← 必须是「人改过的名字」
        return TaskEdit(task: fresh);
      },
    );

    expect(sawName, '人改过的名字',
        reason: 'edit 拿到旧快照的话，整份写回就会把人的改动静默抹掉');
  });

  test('人的改动不会被 Agent 的整份写回抹掉', () async {
    final task = await seedTask(dataDir, name: '原名');
    await repo.save((await repo.findById(task.id))!.copyWith(name: '人改过的名字'));

    await agentMutation().apply(
      taskId: task.id,
      op: 'task.note',
      edit: (fresh) => TaskEdit(task: fresh.copyWith(analysisError: 'x')),
    );

    final after = await repo.findById(task.id);
    expect(after!.name, '人改过的名字');   // 没被抹
    expect(after.analysisError, 'x');     // Agent 自己那笔也在
  });

  test('落盘之后才记日志，而且记的是 op / where / before / after', () async {
    final task = await seedTask(dataDir);
    await agentMutation().apply(
      taskId: task.id,
      op: 'shot.pick',
      where: {'unitUid': 'u-abc', 'shot': 1},
      note: '照参考镜挑的',
      edit: (fresh) => TaskEdit(
        task: fresh,
        before: {'materialId': null},
        after: {'materialId': 105475, 'tags': ['实拍', '厨房']},
      ),
    );

    final entry =
        TaskLogFile(dataDir: dataDir, taskId: task.id).read().single;
    expect(entry.by, ActorKind.agent);
    expect(entry.op, 'shot.pick');
    expect(entry.where['unitUid'], 'u-abc');
    expect(entry.after!['tags'], ['实拍', '厨房']);
    expect(entry.note, '照参考镜挑的');
  });

  test('戳盖在被动过的那一镜上，而且只盖那一镜', () async {
    // 一个单元、两镜。戳要长在 Shot 对象上，不是旁挂在任务上
    final task = await seedTask(dataDir);
    await repo.save((await repo.findById(task.id))!.copyWith(units: [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 3000,
        transcript: '测试台词',
        uid: 'u-abc',
        shots: const [
          Shot(startMs: 0, endMs: 1500),
          Shot(startMs: 1500, endMs: 3000),
        ],
      ),
    ]));

    await TaskMutation(
            repo: repo, dataDir: dataDir, by: ActorKind.human, actor: '人（工作台）')
        .apply(
      taskId: task.id,
      op: 'shot.pick',
      edit: (fresh) => TaskEdit(
        task: fresh,
        stampShots: const [ShotRef('u-abc', 1)],
      ),
    );

    final shots = (await repo.findById(task.id))!.units!.single.shots;
    expect(shots[1].editedBy!.by, ActorKind.human);
    expect(shots[0].editedBy, isNull, reason: '没动过的那一镜不该被盖戳');
  });

  test('单元层的戳盖在单元上，不牵连它下面的镜头', () async {
    final task = await seedTask(dataDir);
    await repo.save((await repo.findById(task.id))!.copyWith(units: [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 3000,
        transcript: '测试台词',
        uid: 'u-abc',
        shots: const [Shot(startMs: 0, endMs: 3000)],
      ),
    ]));

    await agentMutation().apply(
      taskId: task.id,
      op: 'unit.tags',
      edit: (fresh) => TaskEdit(task: fresh, stampUnits: const ['u-abc']),
    );

    final unit = (await repo.findById(task.id))!.units!.single;
    expect(unit.editedBy!.by, ActorKind.agent);
    expect(unit.shots.single.editedBy, isNull);
  });

  test('日志没记上时，数据照落但要出声——不许让人查到「什么都没发生」', () async {
    final task = await seedTask(dataDir);
    // 把 logs 目录做成一个文件，append 就写不进去了
    File('${dataDir.path}/logs').createSync(recursive: true);

    final lines = <String>[];
    final saved = AppLog.sink;
    AppLog.sink = lines.add;
    addTearDown(() => AppLog.sink = saved);

    final got = await agentMutation().apply(
      taskId: task.id,
      op: 'task.note',
      edit: (fresh) => TaskEdit(task: fresh.copyWith(analysisError: 'x')),
    );

    expect(got, isNotNull, reason: '活儿真干成了，不该因为记不上账就算失败');
    expect((await repo.findById(task.id))!.analysisError, 'x');
    expect(lines.join('\n'), contains('没记进日志'));
  });

  test('任务不在就返回 null，不记日志——找不到是事实，不是权限', () async {
    final got = await agentMutation().apply(
      taskId: '不存在',
      op: 'x',
      edit: (fresh) => TaskEdit(task: fresh),
    );
    expect(got, isNull);
    expect(TaskLogFile(dataDir: dataDir, taskId: '不存在').read(), isEmpty);
  });

  test('edit 抛异常时不落盘、不记日志——记了就是假账', () async {
    final task = await seedTask(dataDir, name: '原名');
    await expectLater(
      agentMutation().apply(
          taskId: task.id, op: 'x', edit: (_) => throw StateError('炸了')),
      throwsStateError,
    );
    expect((await repo.findById(task.id))!.name, '原名');
    expect(TaskLogFile(dataDir: dataDir, taskId: task.id).read(), isEmpty);
  });
}
