import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/tagging_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/tagging_resumer.dart';

/// 打标丢了要能补回来。真机上丢过一次：一条刚上传的片子 35 个镜头一个标签、
/// 一句描述都没有，任务状态却是 ready、界面上什么都不说。
class _FakeRepo implements TaskRepository {
  final Map<String, RenewTask> store;
  int saves = 0;
  _FakeRepo(List<RenewTask> tasks)
      : store = {for (final t in tasks) t.id: t};

  @override
  Future<List<RenewTask>> findAll() async => store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => store[id];
  @override
  Future<void> save(RenewTask task) async {
    saves++;
    store[task.id] = task;
  }
  @override
  Future<void> delete(String id) async => store.remove(id);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeTagging implements TaggingService {
  int calls = 0;
  Set<int>? lastOnly;
  final bool fail;
  _FakeTagging({this.fail = false});

  @override
  Future<List<SemanticUnit>> tag(RenewTask task, List<SemanticUnit> units,
      {Set<int>? only, dynamic onProgress}) async {
    calls++;
    lastOnly = only;
    if (fail) throw StateError('云端挂了');
    return [
      for (var i = 0; i < units.length; i++)
        if (only == null || only.contains(i))
          units[i].copyWith(
            tags: const ['促单'],
            shots: [
              for (final s in units[i].shots) s.copyWith(description: '看过了'),
            ],
          )
        else
          units[i],
    ];
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  Shot shot({String? desc}) => Shot(startMs: 0, endMs: 1000, description: desc);
  SemanticUnit unit(List<Shot> shots) => SemanticUnit(
      index: 0, startMs: 0, endMs: 1000, transcript: '一句', shots: shots);
  RenewTask task(String id, List<SemanticUnit> units) => RenewTask(
        id: id, name: '片子 $id', status: RenewTaskStatus.ready,
        createdAt: DateTime(2026), updatedAt: DateTime(2026),
        sourcePath: '/x.mp4', units: units,
      );

  test('欠打标的补上，打过的不重打——重打就是白花一次钱', () async {
    final repo = _FakeRepo([
      task('a', [unit([shot()])]),                 // 欠
      task('b', [unit([shot(desc: '看过了')])]),    // 不欠
    ]);
    final tagging = _FakeTagging();
    final fixed = await TaggingResumer(repository: repo, tagging: tagging)
        .resumeAll();

    expect(fixed, 1);
    expect(tagging.calls, 1, reason: '只该为欠的那条发起一次');
    expect(repo.store['a']!.units!.first.tags, ['促单']);
    expect(repo.store['b']!.units!.first.tags, isEmpty);
  });

  test('只补欠的那几个单元，已经打过的不动', () async {
    final repo = _FakeRepo([
      task('a', [
        unit([shot(desc: '打过了')]),
        unit([shot()]),
      ]),
    ]);
    final tagging = _FakeTagging();
    await TaggingResumer(repository: repo, tagging: tagging).resumeAll();
    expect(tagging.lastOnly, {1}, reason: '第 0 个打过了，重打是白花钱');
  });

  test('补的时候人正在改这条任务：不能拿旧的整个盖回去', () async {
    final repo = _FakeRepo([task('a', [unit([shot()])])]);
    final tagging = _FakeTagging();
    final resumer = TaggingResumer(repository: repo, tagging: tagging);
    // 模拟：打标进行中，人在工作台里把任务改了名
    final before = repo.store['a']!;
    repo.store['a'] = before.copyWith(name: '人刚改的名字');
    await resumer.resumeAll();
    expect(repo.store['a']!.name, '人刚改的名字',
        reason: '拿手上那份旧的整个覆盖回去，会把他刚做的编辑抹掉');
    expect(repo.store['a']!.units!.first.tags, ['促单']);
  });

  test('补失败不该拦住人用软件', () async {
    final repo = _FakeRepo([task('a', [unit([shot()])])]);
    final fixed = await TaggingResumer(
            repository: repo, tagging: _FakeTagging(fail: true))
        .resumeAll();
    expect(fixed, 0);
    expect(repo.store['a'], isNotNull, reason: '任务本身不能因此坏掉');
  });

  test('叫停就停——人要关软件时别继续烧钱', () async {
    final repo = _FakeRepo([
      task('a', [unit([shot()])]),
      task('b', [unit([shot()])]),
    ]);
    final tagging = _FakeTagging();
    var n = 0;
    await TaggingResumer(repository: repo, tagging: tagging)
        .resumeAll(shouldStop: () => n++ > 0);
    expect(tagging.calls, lessThanOrEqualTo(1));
  });
}
