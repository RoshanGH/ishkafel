import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/review_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/agent_request.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/core/storage/task_lock.dart';

/// `ishkafel review list / drop / keep` —— **人在审片台看着，让 Agent 动手**。
///
/// 审片台是「人做决定」的地方，但做决定不等于自己点：人说「第 3、7、12 条
/// 删掉」，它去删，人看着卡片一张张变。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  RenewTask taskWith(List<UnitReplacement> replacements) => RenewTask(
        id: 'r1',
        name: '审核',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 26),
        updatedAt: DateTime.utc(2026, 8, 26),
        units: const [
          SemanticUnit(index: 0, startMs: 0, endMs: 5000, transcript: 'A'),
          SemanticUnit(index: 1, startMs: 5000, endMs: 9000, transcript: 'B'),
        ],
        replacements: replacements,
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_review_agent_');
    repo = FileTaskRepository(dir);
    await repo.save(taskWith([
      UnitReplacement.whole(const [100, 101]),
      UnitReplacement.perShot(const {
        0: [200],
        1: [201, 202],
      }),
    ]));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int> run(List<String> rest,
      {String? items,
      StringSink? out,
      StringSink? err,
      String? file,
      Duration? waitForUi}) {
    return runReviewCommand(
      rest: rest,
      dataDir: dir,
      env: const {},
      appExists: (_) => true,
      items: items,
      file: file,
      waitForUi: waitForUi ?? const Duration(milliseconds: 400),
      out: out,
      err: err,
      run: (_, _) async => ProcessResult(0, 0, '', ''),
    );
  }

  group('list', () {
    test('列出全部待审候选，带上 drop 能直接用的编号', () async {
      final out = StringBuffer();
      expect(await run(['list', 'r1'], out: out), 0);
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(json['total'], 5);
      final first = (json['items'] as List).first as Map<String, dynamic>;
      // 编号要能原样喂回 --items，人不用自己拼
      expect(first['ref'], '0:-:100');
      expect(first['unit'], 0);
      expect(first['material'], 100);
    });
  });

  group('drop', () {
    test('剔掉两条：任务里就真的少了这两条，其余不动', () async {
      expect(await run(['drop', 'r1'], items: '0:-:100, 1:1:202'), 0);
      final after = await repo.findById('r1');
      expect(after!.replacements![0].wholeCandidateIds, const [101]);
      expect(after.replacements![1].shotCandidateIds[1], const [201]);
      expect(after.replacements![1].shotCandidateIds[0], const [200]);
    });

    test('编号写错：整批不落盘，一次把问题全报出来', () async {
      final err = StringBuffer();
      final code = await run(['drop', 'r1'],
          items: '0:-:100, 9:-:999, 8:-:888', err: err);
      expect(code, exitBadUsage);
      expect(err.toString(), contains('999'));
      expect(err.toString(), contains('888'));
      // 合法的那条也不能落——不然人以为删了三条、实际删了一条
      final after = await repo.findById('r1');
      expect(after!.replacements![0].wholeCandidateIds, const [100, 101]);
    });

    test('干完把在场状态撤掉，界面立刻能动', () async {
      expect(await run(['drop', 'r1'], items: '0:-:100'), 0);
      expect(readAgentPresence(dataDir: dir, taskId: 'r1'), isNull);
    });

    test('另一个 Agent 占着就写不进去，明说是谁', () async {
      // 用**别的**进程号：同一个持有者不算冲突，会直接写进去。
      // 不能拿 pid+1——并行跑测试时那个进程可能真的存在，
      // 锁到底算不算失效就成了掷骰子（真机上全量跑时挂过）
      final other = 'agent:$pid 的另一个会话';
      TaskLockFile(dataDir: dir, taskId: 'r1').acquire(other);
      final err = StringBuffer();
      expect(await run(['drop', 'r1'], items: '0:-:100', err: err), exitLocked);
      expect(err.toString(), contains(other));
    });
  });

  /// 人正开着审片台看着指挥 Agent：**这不是冲突，是委派**。
  ///
  /// 界面持锁时 Agent 不自己写盘——审片台上剔掉的卡是界面里的临时状态，
  /// 人按「确认」才落盘，绕过界面写盘会让人还没确认盘上就变了。
  group('界面开着时委派给界面', () {
    setUp(() {
      TaskLockFile(dataDir: dir, taskId: 'r1').acquire('人（审核中）');
    });

    test('下单给界面并等回执，不自己写盘', () async {
      final out = StringBuffer();
      // 扮演界面：取单、干活、交活
      final ui = Future<void>(() async {
        for (var i = 0; i < 40; i++) {
          final req = consumeAgentRequest(dataDir: dir, taskId: 'r1');
          if (req != null) {
            expect(req.kind, 'review.drop');
            expect((req.payload['decisions'] as List), hasLength(1));
            writeAgentRequestResult(
                dataDir: dir, taskId: 'r1', id: req.id,
                ok: true, message: '已标记 1 条');
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      final code = await run(['drop', 'r1'], items: '0:-:100', out: out);
      await ui;
      expect(code, 0);
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(json['delegated'], isTrue);
      // 盘上不能变——人还没按确认
      final after = await repo.findById('r1');
      expect(after!.replacements![0].wholeCandidateIds, const [100, 101]);
      // 必须说清还没落盘，不然人以为完事了，关掉窗口就白干
      expect(json['next'] as String, contains('确认'));
    });

    test('界面没回应：报失败，不能报成功', () async {
      final err = StringBuffer();
      final code = await run(['drop', 'r1'], items: '0:-:100', err: err);
      expect(code, isNot(0));
      expect(err.toString(), contains('没有回应'));
    });

    test('界面报失败就把原因原样带回来', () async {
      final err = StringBuffer();
      final ui = Future<void>(() async {
        for (var i = 0; i < 40; i++) {
          final req = consumeAgentRequest(dataDir: dir, taskId: 'r1');
          if (req != null) {
            writeAgentRequestResult(
                dataDir: dir, taskId: 'r1', id: req.id,
                ok: false, message: '这张卡不在当前页面上');
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      final code = await run(['drop', 'r1'], items: '0:-:100', err: err);
      await ui;
      expect(code, isNot(0));
      expect(err.toString(), contains('这张卡不在当前页面上'));
    });
  });

  group('keep', () {
    test('恢复是空操作但要如实回报——它本来就在', () async {
      final out = StringBuffer();
      expect(await run(['keep', 'r1'], items: '0:-:100', out: out), 0);
      final after = await repo.findById('r1');
      expect(after!.replacements![0].wholeCandidateIds, const [100, 101]);
      expect(jsonDecode(out.toString())['kept'], 1);
    });
  });

  test('没给 --items 时说清用法，不当成「全删」', () async {
    final err = StringBuffer();
    expect(await run(['drop', 'r1'], err: err), exitBadUsage);
    expect(err.toString(), contains('--items'));
  });

  test('review <id> 这条老用法照旧——不能因为加了子命令就变味', () async {
    final err = StringBuffer();
    expect(await run(['r1'], err: err), 0);
    expect(err.toString(), contains('审核界面已打开'));
  });
}
