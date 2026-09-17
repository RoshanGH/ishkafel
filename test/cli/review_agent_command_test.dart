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
import 'package:ishkafel/core/storage/ui_where.dart';

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
          SemanticUnit(uid: 'u0',index: 0, startMs: 0, endMs: 5000, transcript: 'A'),
          SemanticUnit(uid: 'u1',index: 1, startMs: 5000, endMs: 9000, transcript: 'B'),
        ],
        // 测试里的单元身份统一用 'u0'/'u1'…，方案按位置铺到它们身上
        replacementsByUid: {
          for (var i = 0; i < replacements.length; i++) 'u$i': replacements[i],
        },
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
      expect(after!.replacementsByUid['u0']!.wholeCandidateIds, const [101]);
      expect(after.replacementsByUid['u1']!.shotCandidateIds[1], const [201]);
      expect(after.replacementsByUid['u1']!.shotCandidateIds[0], const [200]);
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
      expect(after!.replacementsByUid['u0']!.wholeCandidateIds, const [100, 101]);
    });

    test('干完把在场状态撤掉，界面立刻能动', () async {
      expect(await run(['drop', 'r1'], items: '0:-:100'), 0);
      expect(readAgentPresence(dataDir: dir, taskId: 'r1'), isNull);
    });

    test('另一个 Agent 正在动这条任务：照样写得进去，不会被挡住', () async {
      // 锁删掉之后**没有任何一条路径会因为「有人占着」而失败**。
      // 两边同时写不再互相抹掉：唯一写入口 TaskMutation 落盘前重读 + 版本
      // 校验，被抢写就重跑一轮；谁改了什么，改动日志里都有
      writeAgentPresence(
        dataDir: dir,
        taskId: 'r1',
        presence: AgentPresence(
            holder: 'agent:另一个会话',
            at: DateTime.now(),
            action: '正在剔素材'),
      );
      expect(await run(['drop', 'r1'], items: '0:-:100'), 0);
    });
  });

  /// 人正开着审片台看着指挥 Agent：**这不是冲突，是委派**——但委派是
  /// **首选路径，不是必经之路**（2026-09-17 第一批 任务 8）。界面确实
  /// 停在这条任务上才试着委派；它接了单但没应，就秒级兜底自己直写，
  /// 不再报失败——可视化一出问题不该把 Agent 挡住。
  group('界面开着时委派给界面', () {
    setUp(() {
      // 委派只在界面确实停在这条任务上时才有意义——不写这一句，
      // delegateOrDoItYourself 会判定 onScene 为 false，直接零等待自己写
      writeUiWhere(dir, module: 'review', taskId: 'r1');
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
      expect(after!.replacementsByUid['u0']!.wholeCandidateIds, const [100, 101]);
      // 必须说清还没落盘，不然人以为完事了，关掉窗口就白干
      expect(json['next'] as String, contains('确认'));
    });

    /// **委派降级成首选路径 + 秒级兜底**（2026-09-17 第一批 任务 8）：
    /// 以前这里断言「界面没回应 → 报失败」，那正是这次要清零的东西——
    /// 可视化一出问题就把 Agent 挡住，因果是反的。现在没应就秒级兜底
    /// 自己直写，一样把决定落进任务，不再当成失败
    test('界面没回应：不再报失败，秒级兜底自己直写', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await run(['drop', 'r1'], items: '0:-:100', out: out, err: err);
      expect(code, 0, reason: '界面没应不该让 Agent 卡住——它能自己直写落盘');
      expect(err.toString(), contains('直接自己'),
          reason: '还是要如实说这是自己直写的，不是界面做成的');
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(json['delegated'], isNot(true), reason: '这条是自己直写的，不是委派成的');
      expect(json['dropped'], 1);
      // 这回真落盘了——不用等人按确认，因为压根没人在等着确认
      final after = await repo.findById('r1');
      expect(after!.replacementsByUid['u0']!.wholeCandidateIds, const [101]);
    });

    /// **人恰好开着「另一页」不是失败。**
    ///
    /// 界面在这条任务上、但停在**工作台**——它不认识 `review.drop`。
    /// 那句「我接不了」说的是「人开着另一页」，不是「这件事做不成」；
    /// 当真失败往上抛，Agent 得到的就是「我做不了，因为软件那边不让」。
    test('界面在这条任务上、但是接不了的那一页：自己直写，不报失败', () async {
      final err = StringBuffer();
      final out = StringBuffer();
      final ui = Future<void>(() async {
        for (var i = 0; i < 400; i++) {
          final req = consumeAgentRequest(dataDir: dir, taskId: 'r1');
          if (req != null) {
            writeAgentRequestResult(
                dataDir: dir, taskId: 'r1', id: req.id,
                ok: false, unsupported: true,
                message: '工作台接不了「${req.kind}」这件事——你自己做就行');
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      final code =
          await run(['drop', 'r1'], items: '0:-:100', err: err, out: out);
      await ui;

      expect(code, 0, reason: '人开着另一页不该让 Agent 失败');
      expect(err.toString(), contains('我自己剔除'));
      final after = await repo.findById('r1');
      expect(after!.replacementsByUid['u0']!.wholeCandidateIds, const [101],
          reason: '活儿真的干了，不是报个成功了事');
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

  /// 界面开着，但它并不在这条任务上（比如打开过又切走了）：
  /// **零等待，直接自己直写**——委派只在人确实看着的时候才有意义，
  /// 少了这条判断，界面开着但没看这条任务时每条写命令都要白等一次超时
  group('界面开着但不在这条任务上', () {
    setUp(() {
      writeUiWhere(dir, module: 'review', taskId: 'r999');
    });

    test('零等待，直接自己直写，不试着委派', () async {
      final sw = Stopwatch()..start();
      final out = StringBuffer();
      final code = await run(['drop', 'r1'], items: '0:-:100', out: out);
      sw.stop();
      expect(code, 0);
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 300)),
          reason: '界面不在这条任务上，没有委派的理由，不该等');
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(json['delegated'], isNot(true));
      final after = await repo.findById('r1');
      expect(after!.replacementsByUid['u0']!.wholeCandidateIds, const [101]);
    });
  });

  group('keep', () {
    test('恢复是空操作但要如实回报——它本来就在', () async {
      final out = StringBuffer();
      expect(await run(['keep', 'r1'], items: '0:-:100', out: out), 0);
      final after = await repo.findById('r1');
      expect(after!.replacementsByUid['u0']!.wholeCandidateIds, const [100, 101]);
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
