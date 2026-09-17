import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/apply_command.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/storage/agent_request.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/core/storage/ui_where.dart';

/// `apply plans` **委派是首选路径，不是必经之路**（2026-09-17 第一批
/// 任务 8）。以前是「委派 → 等界面 90 秒 → 超时 → 报『界面没有回应』」；
/// 现在先看界面在不在这条任务上，不在就零等待自己直写，在但没应就秒级
/// 兜底自己直写——两条路径落盘的都是同一份 `_commitPlans`，人看到的和
/// 落盘的同源这条规矩没有破。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  RenewTask task() => RenewTask(
        id: 't1',
        name: '委派',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 18),
        updatedAt: DateTime.utc(2026, 9, 18),
        units: const [
          SemanticUnit(
              uid: 'u0', index: 0, startMs: 0, endMs: 3000, transcript: 'A'),
        ],
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_apply_delegate_');
    repo = FileTaskRepository(dir);
    await repo.save(task());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const plansJson = '''
  {"plans": [
    {"name": "方案甲", "units": [
      {"unit": 0, "mode": "whole", "material": 101}
    ]}
  ]}
  ''';

  Future<int> apply({StringSink? out, StringSink? err}) async {
    final f = File('${dir.path}/plans_in.json')..writeAsStringSync(plansJson);
    return runApplyCommand(
      rest: ['plans', 't1'],
      file: f.path,
      dataDir: dir,
      contentService: MiaoaContentService(
          gateway: MiaoaGateway(
              run: (_, _) async => ProcessResult(1, 0, '{"records":[]}', ''),
              binary: 'miaoa')),
      err: err ?? StringBuffer(),
      out: out ?? StringBuffer(),
    );
  }

  test('界面开着但不在这条任务上：零等待，自己直写', () async {
    // 故意把 ui_where 写成别的任务——onScene 应该判定为 false
    writeUiWhere(dir, module: 'workbench', taskId: 't999');

    final sw = Stopwatch()..start();
    final code = await apply();
    sw.stop();

    expect(code, 0);
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 500)),
        reason: '界面不在这条任务上，没有委派的理由，不该等');
    final updated = await repo.findById('t1');
    expect(updated!.replacementsByUid['u0']!.wholeCandidateIds, const [101]);
  });

  test('界面就在这条任务上：走委派，界面应了就用界面落盘的那份', () async {
    writeUiWhere(dir, module: 'workbench', taskId: 't1');

    final ui = Future<void>(() async {
      for (var i = 0; i < 100; i++) {
        final req = consumeAgentRequest(dataDir: dir, taskId: 't1');
        if (req != null) {
          expect(req.kind, 'plans.apply');
          writeAgentRequestResult(
              dataDir: dir, taskId: 't1', id: req.id,
              ok: true, message: '界面已经投影上去了');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final out = StringBuffer();
    final code = await apply(out: out);
    await ui;

    expect(code, 0);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['via'], 'ui');
    expect(json['message'], contains('投影'));
  });

  test('界面在，但秒级超时没应：兜底自己直写，绝不报失败', () async {
    writeUiWhere(dir, module: 'workbench', taskId: 't1');

    final out = StringBuffer();
    final code = await apply(out: out);

    expect(code, 0, reason: '界面没应不该让 Agent 卡住——它能自己直写');
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['via'], isNot('ui'), reason: '这条是自己直写落的盘');
    final updated = await repo.findById('t1');
    expect(updated!.replacementsByUid['u0']!.wholeCandidateIds, const [101]);
  });

  /// **人恰好开着「另一页」不是失败。**
  ///
  /// 界面在这条任务上、但停在审片台——它不认识 `plans.apply`。
  /// 那句「我接不了」说的是「人开着另一页」，不是「这件事做不成」，
  /// 当真失败往上抛就又变回了「我做不了，因为软件那边不让」。
  test('界面在这条任务上、但是接不了的那一页：自己直写，不报失败', () async {
    writeUiWhere(dir, module: 'review', taskId: 't1');

    final ui = Future<void>(() async {
      for (var i = 0; i < 400; i++) {
        final req = consumeAgentRequest(dataDir: dir, taskId: 't1');
        if (req != null) {
          writeAgentRequestResult(
              dataDir: dir, taskId: 't1', id: req.id,
              ok: false, unsupported: true,
              message: '审片台接不了「${req.kind}」这件事——你自己做就行');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    final out = StringBuffer();
    final err = StringBuffer();
    final code = await apply(out: out, err: err);
    await ui;

    expect(code, 0, reason: '人开着另一页不该让 Agent 失败');
    expect(err.toString(), contains('我自己写'));
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['via'], isNot('ui'), reason: '这条是自己直写落的盘');
    final updated = await repo.findById('t1');
    expect(updated!.replacementsByUid['u0']!.wholeCandidateIds, const [101],
        reason: '活儿真的干了，不是报个成功了事');
  });

  test('界面在，明确回了拒绝：不兜底，原样把拒绝理由带回去', () async {
    writeUiWhere(dir, module: 'workbench', taskId: 't1');

    final ui = Future<void>(() async {
      for (var i = 0; i < 100; i++) {
        final req = consumeAgentRequest(dataDir: dir, taskId: 't1');
        if (req != null) {
          writeAgentRequestResult(
              dataDir: dir, taskId: 't1', id: req.id,
              ok: false, message: '这个页面已经关掉了');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final err = StringBuffer();
    final code = await apply(err: err);
    await ui;

    expect(code, isNot(0), reason: '这是界面真的答复了，不是没应，不该兜底改成功');
    expect(err.toString(), contains('这个页面已经关掉了'));
    // 盘上不能变——界面说没做成
    final updated = await repo.findById('t1');
    expect(updated!.replacementsByUid, isEmpty);
  });
}
