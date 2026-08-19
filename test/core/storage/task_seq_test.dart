import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/core/storage/task_seq.dart';

/// 任务短编号：人跟 Agent 沟通的指代锚点（「把 #12 导出」）。
class _MemoryRepo implements TaskRepository {
  final store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async => store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => store[id];
  @override
  Future<void> save(RenewTask task) async => store[task.id] = task;
  @override
  Future<void> delete(String id) async => store.remove(id);
}

RenewTask task(String id, {int? seq, DateTime? createdAt}) => RenewTask(
      id: id,
      seq: seq,
      name: '任务$id',
      sourcePath: '/v/$id.mp4',
      status: RenewTaskStatus.ready,
      createdAt: createdAt ?? DateTime.utc(2026, 8, 1),
      updatedAt: DateTime.utc(2026, 8, 1),
    );

void main() {
  test('分配：现存最大号 +1；空库从 1 开始', () async {
    final repo = _MemoryRepo();
    expect(await nextTaskSeq(repo), 1);
    repo.store['a'] = task('a', seq: 3);
    repo.store['b'] = task('b', seq: 7);
    expect(await nextTaskSeq(repo), 8);
  });

  test('补号：老任务按创建时间从早到晚补，已有号的不动，且落库', () async {
    final repo = _MemoryRepo();
    repo.store['old2'] = task('old2', createdAt: DateTime.utc(2026, 7, 2));
    repo.store['old1'] = task('old1', createdAt: DateTime.utc(2026, 7, 1));
    repo.store['new'] = task('new', seq: 5);

    final result = await ensureTaskSeqs(repo, repo.store.values.toList());

    final byId = {for (final t in result) t.id: t};
    expect(byId['old1']!.seq, 6, reason: '最早创建的先拿号，从现存最大号后接着排');
    expect(byId['old2']!.seq, 7);
    expect(byId['new']!.seq, 5, reason: '已有号的不动');
    expect(repo.store['old1']!.seq, 6, reason: '补号要落库，不是只改内存');
  });

  test('补号幂等：都有号时原样返回、不写库', () async {
    final repo = _MemoryRepo();
    final tasks = [task('a', seq: 1), task('b', seq: 2)];
    expect(identical(await ensureTaskSeqs(repo, tasks), tasks), isTrue);
  });

  test('解析：id 精确 > #N > 纯数字 N；找不到返回 null', () async {
    final repo = _MemoryRepo();
    repo.store['abc'] = task('abc', seq: 12);
    expect((await resolveTaskRef(repo, 'abc'))?.id, 'abc');
    expect((await resolveTaskRef(repo, '#12'))?.id, 'abc');
    expect((await resolveTaskRef(repo, '12'))?.id, 'abc');
    expect(await resolveTaskRef(repo, '#99'), isNull);
    expect(await resolveTaskRef(repo, '不存在'), isNull);
  });

  test('id 本身是数字时优先按 id 匹配（id 是机器身份，永远精确优先）', () async {
    final repo = _MemoryRepo();
    repo.store['12'] = task('12', seq: 1);
    repo.store['x'] = task('x', seq: 12);
    expect((await resolveTaskRef(repo, '12'))?.id, '12');
  });
}
