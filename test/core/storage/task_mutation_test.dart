import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_edit_ops.dart';
import 'package:ishkafel/core/log/app_log.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/edit_stamp.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/core/storage/task_log.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/task_mutation.dart';

import '../../support/seed_task.dart';

/// 只让 `save` 抛出去，`findById` 照常返回构造时给的那份。
/// 用来验证「落盘之后才记日志」这条顺序——不是靠内容碰巧对得上。
class _ThrowingSaveRepo implements TaskRepository {
  final RenewTask task;
  _ThrowingSaveRepo(this.task);

  @override
  Future<List<RenewTask>> findAll() async => [task];
  @override
  Future<RenewTask?> findById(String id) async => id == task.id ? task : null;
  @override
  Future<void> save(RenewTask task) async => throw StateError('盘满了');
  @override
  Future<void> delete(String id) async {}
}

/// 按调用次序把 [reads] 里的版本依次交给 `findById`（超出长度后一直返回
/// 最后一个），模拟「窗口内被另一个写入方抢写」——真实文件系统上这种撞车
/// 撞不出稳定的时序，只能靠这样的假 repo 精确摆出「第几次读到第几个版本」。
class _RacingRepo implements TaskRepository {
  final List<RenewTask> reads;
  int _calls = 0;
  RenewTask? saved;
  _RacingRepo(this.reads);

  @override
  Future<List<RenewTask>> findAll() async => reads.isEmpty ? [] : [reads.last];
  @override
  Future<RenewTask?> findById(String id) async {
    final v = reads[_calls < reads.length ? _calls : reads.length - 1];
    _calls++;
    return v;
  }

  @override
  Future<void> save(RenewTask task) async => saved = task;
  @override
  Future<void> delete(String id) async {}
}

RenewTask _bareTask(String id,
        {String name = '原名', required DateTime updatedAt}) =>
    RenewTask(
      id: id,
      name: name,
      status: RenewTaskStatus.ready,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );

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

  test('日志内容对得上 op / where / before / after（顺序另有测试单独守）', () async {
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

  test('顺序是先落盘再记账：save 失败就不该有这一笔日志，否则就是假账', () async {
    final task = await seedTask(dataDir);
    final throwingRepo = _ThrowingSaveRepo(task);
    final mutation = TaskMutation(
        repo: throwingRepo, dataDir: dataDir, by: ActorKind.agent, actor: 'Agent');

    // 之前把 append 挪到 save 之前，8 条测试原样全绿——内容对得上不等于
    // 顺序对，只有真的让 save 炸掉才能验出这条顺序
    await expectLater(
      mutation.apply(
          taskId: task.id, op: 'x', edit: (fresh) => TaskEdit(task: fresh)),
      throwsStateError,
    );

    expect(TaskLogFile(dataDir: dataDir, taskId: task.id).read(), isEmpty,
        reason: 'save 都没成功，日志里不该凭空多出这一笔');
  });

  test('戳盖在被动过的那一镜上，而且只盖那一镜——返回值和落盘的都要有', () async {
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

    final got = await TaskMutation(
            repo: repo, dataDir: dataDir, by: ActorKind.human, actor: '人（工作台）')
        .apply(
      taskId: task.id,
      op: 'shot.pick',
      edit: (fresh) => TaskEdit(
        task: fresh,
        stampShots: const [ShotRef('u-abc', 1)],
      ),
    );

    // 返回值本身就要带戳，不能只有落盘那份对——界面多半直接拿返回值刷新
    final gotShots = got!.units!.single.shots;
    expect(gotShots[1].editedBy!.by, ActorKind.human);
    expect(gotShots[0].editedBy, isNull);

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

  test('点名的单元找不到时要出声，不能悄悄丢戳', () async {
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

    final lines = <String>[];
    final saved = AppLog.sink;
    AppLog.sink = lines.add;
    addTearDown(() => AppLog.sink = saved);

    await agentMutation().apply(
      taskId: task.id,
      op: 'unit.tags',
      // 'u-abc' 拼错了——这个 uid 在任务里根本不存在
      edit: (fresh) => TaskEdit(task: fresh, stampUnits: const ['u-不存在']),
    );

    expect(lines.join('\n'), contains('u-不存在'),
        reason: '戳点了名却没找到目标，不该悄无声息地什么都不做');
  });

  test('点名的镜头下标越界时要出声，不能悄悄丢戳', () async {
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

    final lines = <String>[];
    final saved = AppLog.sink;
    AppLog.sink = lines.add;
    addTearDown(() => AppLog.sink = saved);

    await agentMutation().apply(
      taskId: task.id,
      op: 'shot.pick',
      // 这个单元只有 1 镜（下标 0），5 越界
      edit: (fresh) =>
          TaskEdit(task: fresh, stampShots: const [ShotRef('u-abc', 5)]),
    );

    expect(lines.join('\n'), contains('u-abc#5'));
  });

  test('空 uid 的单元不会被误伤——还没发身份的单元不认盖戳请求', () async {
    final task = await seedTask(dataDir);
    await repo.save((await repo.findById(task.id))!.copyWith(units: [
      // uid 留空：模拟老存档 / 刚拆分出来还没跑 ensureUnitUids 的单元
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 1000,
        transcript: 'A',
        shots: const [Shot(startMs: 0, endMs: 1000)],
      ),
      SemanticUnit(
        index: 1,
        startMs: 1000,
        endMs: 2000,
        transcript: 'B',
        shots: const [Shot(startMs: 1000, endMs: 2000)],
      ),
    ]));

    await agentMutation().apply(
      taskId: task.id,
      op: 'unit.tags',
      edit: (fresh) => TaskEdit(task: fresh, stampUnits: const ['']),
    );

    final units = (await repo.findById(task.id))!.units!;
    expect(units[0].editedBy, isNull, reason: '空 uid 不该一次命中所有空 uid 单元');
    expect(units[1].editedBy, isNull);
  });

  test('拆镜头之后再盖戳：下标按 edit 返回的那份算，不是按 fresh', () async {
    final task = await seedTask(dataDir);
    await repo.save((await repo.findById(task.id))!.copyWith(units: [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 3000,
        transcript: '测试台词',
        uid: 'u-abc',
        // 只有一镜，拆完变两镜——fresh 里压根没有下标 2
        shots: const [Shot(startMs: 0, endMs: 3000)],
      ),
    ]));

    await agentMutation().apply(
      taskId: task.id,
      op: 'shot.split',
      edit: (fresh) {
        final split = SegmentationEditOps.splitShotAt(
          fresh.units!,
          0,
          2250,
          fps: 30,
          shotIndex: 0,
        )!;
        // 拆完这一单元有两镜：[0] 原镜左半，[1] 新拆出来的右半——
        // 这个下标只有在拆完之后才存在，是相对拆完那份算的
        return TaskEdit(
          task: fresh.copyWith(units: split),
          stampShots: const [ShotRef('u-abc', 1)],
        );
      },
    );

    final shots = (await repo.findById(task.id))!.units!.single.shots;
    expect(shots.length, 2, reason: '拆分应该真的生效了');
    expect(shots[1].editedBy!.by, ActorKind.agent, reason: '戳该落在拆出来的右半镜上');
    expect(shots[0].editedBy, isNull, reason: '左半镜没被点名，不该被盖戳');
  });

  test('每一笔经过 apply 的写入都要把 updatedAt 推到当时——不靠调用方自己记得写',
      () async {
    final task = await seedTask(dataDir);
    final before = (await repo.findById(task.id))!.updatedAt;

    final got = await agentMutation().apply(
      taskId: task.id,
      op: 'task.note',
      edit: (fresh) => TaskEdit(task: fresh),
    );

    expect(got!.updatedAt.isAfter(before), isTrue);
    expect((await repo.findById(task.id))!.updatedAt, got.updatedAt);
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

  test('落盘前发现被抢写：重读一次、重跑 edit，最终按新数据落盘', () async {
    final t0 = _bareTask('t-race-1',
        name: '原名', updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 0));
    // 抢写者把名字改了，同时 updatedAt 往前推——这是「有人在这段窗口里写过」
    // 唯一能让 apply 察觉到的信号
    final t1 = t0.copyWith(
        name: '人改过的名字', updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1));
    // 三次 findById：①初读拿到 t0 ②落盘前核一次发现被抢写、拿到 t1
    // ③重跑 edit 之后再核一次，还是 t1，说明这次没人再抢
    final racingRepo = _RacingRepo([t0, t1, t1]);

    final seenNames = <String>[];
    final got = await TaskMutation(
            repo: racingRepo, dataDir: dataDir, by: ActorKind.agent, actor: 'Agent')
        .apply(
      taskId: 't-race-1',
      op: 'task.note',
      edit: (fresh) {
        seenNames.add(fresh.name);
        return TaskEdit(task: fresh.copyWith(analysisError: 'x'));
      },
    );

    expect(seenNames, ['原名', '人改过的名字'],
        reason: '第一次读到的那份被抢写过，edit 要按新数据重跑一次');
    expect(got!.name, '人改过的名字', reason: '最终落盘的是基于新数据算出来的结果');
    expect(racingRepo.saved!.name, '人改过的名字');
    expect(racingRepo.saved!.analysisError, 'x', reason: '重跑那一次的改动也要在');
  });

  test('重试一轮还是被抢写：不再无限重试，数据照落但要点名说清', () async {
    final t0 = _bareTask('t-race-2', updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 0));
    final t1 = t0.copyWith(updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1));
    final t2 = t0.copyWith(updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 2));
    // ①初读 t0 ②核一次发现被抢写、拿到 t1，重跑 edit ③再核一次，
    // 又变成 t2——重试之后窗口里还是有人在写
    final racingRepo = _RacingRepo([t0, t1, t2]);

    final lines = <String>[];
    final saved = AppLog.sink;
    AppLog.sink = lines.add;
    addTearDown(() => AppLog.sink = saved);

    var editCalls = 0;
    final got = await TaskMutation(
            repo: racingRepo, dataDir: dataDir, by: ActorKind.agent, actor: 'Agent')
        .apply(
      taskId: 't-race-2',
      op: 'task.note',
      edit: (fresh) {
        editCalls++;
        return TaskEdit(task: fresh.copyWith(analysisError: 'x'));
      },
    );

    expect(editCalls, 2, reason: '只重试一轮，不是无限重试到一致为止');
    expect(got, isNotNull, reason: '写窗口挤不该让这一笔活儿失败');
    expect(lines.join('\n'), contains('抢写'));
  });
}
