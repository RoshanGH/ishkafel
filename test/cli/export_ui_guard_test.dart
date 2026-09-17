import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/apply_command.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/export_command.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/agent_request.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/core/storage/task_media.dart';
import 'package:ishkafel/core/storage/ui_action.dart';
import 'package:ishkafel/core/storage/ui_where.dart';

/// `export` 委派的**门槛**：界面确实停在这条任务上才请它代办。
///
/// 这一段原来深埋在「界面占着锁」里——于是人最想看着的一步恰恰因为
/// 「人在看」才走得通，反过来人不在时还要先撞一次锁、被告知
/// 「别人正在操作这个任务，导不了」。因果是反的。
///
/// 委派的**交互不变**：打开导出对话框、参数填好，最后那一下由人点
/// （导出跑几分钟、直接出交付物、又花钱，不替他点）。变的是门槛和兜底：
/// 界面不在场就根本不委派，界面没接单也绝不返回失败。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  RenewTask task() => RenewTask(
        id: 't1',
        name: '导出门槛',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 18),
        updatedAt: DateTime.utc(2026, 9, 18),
        units: const [
          SemanticUnit(
              uid: 'u0',
              index: 0,
              startMs: 0,
              endMs: 3000,
              transcript: 'A',
              shots: [Shot(startMs: 0, endMs: 3000)]),
        ],
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('exp_guard_');
    repo = FileTaskRepository(dir);
    await repo.save(task());
    final f = File('${dir.path}/plans_in.json')
      ..writeAsStringSync('{"plans":[{"name":"方案甲","units":'
          '[{"unit":0,"mode":"whole","material":101}]}]}');
    final code = await runApplyCommand(
      rest: ['plans', 't1'],
      file: f.path,
      dataDir: dir,
      // 测试不打网络
      contentService: MiaoaContentService(
          gateway: MiaoaGateway(
              run: (_, _) async => ProcessResult(1, 0, '{"records":[]}', ''),
              binary: 'miaoa')),
      err: StringBuffer(),
      out: StringBuffer(),
    );
    expect(code, 0, reason: '前置条件：方案得先提交上');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('界面就在这条任务上：请它把导出对话框打开，最后那一下留给人', () async {
    writeUiWhere(dir, module: 'workbench', taskId: 't1');

    final out = StringBuffer();
    final running = runExportCommand(
      rest: ['t1'],
      dataDir: dir,
      outputDir: '${dir.path}/out',
      out: out,
      err: StringBuffer(),
    );
    // 扮演界面：取单、把对话框打开、交活
    AgentRequest? got;
    for (var i = 0; i < 200 && got == null; i++) {
      got = consumeAgentRequest(dataDir: dir, taskId: 't1');
      if (got == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    expect(got, isNotNull, reason: '人开着这一页，就该请界面代办');
    expect(got!.kind, UiAction.exportOpen.wire);
    expect(got.payload['outputDir'], '${dir.path}/out');
    writeAgentRequestResult(
        dataDir: dir, taskId: 't1', id: got.id, ok: true, message: '对话框开好了');

    expect(await running, 0);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['via'], 'ui');
    expect(json['exported'], isFalse,
        reason: '对话框只是开着，人还没点——别让调用方以为导完了');
  });

  /// **人恰好开着「另一页」不是失败。**
  ///
  /// `delegateOrDoItYourself` 只问「界面在不在这条任务上」，问不了
  /// 「这一页能不能接这个动作」。人在**审片台**看这条任务时，导出的委派
  /// 会收到审片台那句「我不认识 export.open」——把它当真失败往上抛，
  /// Agent 得到的就是「我做不了，因为软件那边不让」，理由竟然是人开着另一页。
  ///
  /// 而这条路在主流程上：「Agent 挑完素材 → 人在审片台过一遍 →
  /// Agent 接着 export」正是手册推荐的走法。
  test('界面在这条任务上、但是接不了的那一页：自己导，不报失败', () async {
    writeUiWhere(dir, module: 'review', taskId: 't1');
    TaskMedia(dataDir: dir, taskId: 't1').materialsDir.createSync(recursive: true);
    File(p.join(
        TaskMedia(dataDir: dir, taskId: 't1').materialsDir.path, '101.mp4'))
      ..createSync()
      ..writeAsStringSync('不是真视频');

    // 扮演审片台：取单，回一句「我接不了」并带上 unsupported
    final ui = Future<void>(() async {
      for (var i = 0; i < 400; i++) {
        final req = consumeAgentRequest(dataDir: dir, taskId: 't1');
        if (req != null) {
          writeAgentRequestResult(
              dataDir: dir,
              taskId: 't1',
              id: req.id,
              ok: false,
              unsupported: true,
              message: '审片台接不了「${req.kind}」这件事——你自己做就行');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    final err = StringBuffer();
    final code = await runExportCommand(
      rest: ['t1'],
      dataDir: dir,
      outputDir: '${dir.path}/out',
      out: StringBuffer(),
      err: err,
    );
    await ui;

    expect(err.toString(), contains('我自己导'),
        reason: '「这一页接不了」要当成「没人接」，自己干');
    expect(code, isNot(exitEnv),
        reason: '绝不能因为人开着另一页就报环境错');
    expect(err.toString(), isNot(contains('没能打开导出')),
        reason: '那句话是给「界面真的试了、没做成」准备的');
  });

  test('界面开着但不在这条任务上：根本不委派，一单都不下', () async {
    writeUiWhere(dir, module: 'workbench', taskId: 't999');

    // 把素材先放进任务名下的缓存里：**这条测试不许打网络**，
    // 否则「有没有敲界面的门」这件事会被一次素材下载的快慢左右
    TaskMedia(dataDir: dir, taskId: 't1').materialsDir.createSync(recursive: true);
    File(p.join(
        TaskMedia(dataDir: dir, taskId: 't1').materialsDir.path, '101.mp4'))
      ..createSync()
      ..writeAsStringSync('不是真视频，导出会在 ffmpeg 那一步失败——这里不关心');

    final err = StringBuffer();
    // 这条会一路走到真导出（素材不是真视频，导不成）——
    // 这里只关心**它有没有去敲界面的门**
    await runExportCommand(
      rest: ['t1'],
      dataDir: dir,
      outputDir: '${dir.path}/out',
      out: StringBuffer(),
      err: err,
    ).timeout(const Duration(seconds: 60), onTimeout: () => -1);

    expect(consumeAgentRequest(dataDir: dir, taskId: 't1'), isNull,
        reason: '界面不在这条任务上，没有委派的理由——'
            '下了单也只会在那儿挂到超时，白等一次');
    expect(err.toString(), isNot(contains('已请界面')));
  });
}
