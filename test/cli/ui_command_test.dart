import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/ui_command.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/agent_request.dart';

/// `ishkafel ui new-task` —— **当着人的面**新建任务。
///
/// 和 `script new` 的区别不是结果，是过程：那条在后台把任务建好、界面
/// 一动不动（真机上就是这样，用户说「建了任务 5，界面什么都没发生」）；
/// 这一条会把软件拉起来、真的弹出向导、真的填、真的点创建。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ui_cmd_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int> run(List<String> rest,
      {String? mode,
      String? file,
      String? tagGroups,
      StringSink? out,
      StringSink? err,
      Duration? wait}) =>
      runUiCommand(
        rest: rest,
        dataDir: dir,
        mode: mode,
        file: file,
        tagGroups: tagGroups,
        env: const {},
        waitForUi: wait ?? const Duration(milliseconds: 300),
        out: out,
        err: err,
        run: (_, __) async => ProcessResult(0, 0, '', ''),
      );

  test('参数不对时**不弹向导**——让人看着窗口弹出来又关掉，比不弹更糟', () async {
    final err = StringBuffer();
    // renew 没给原片
    expect(await run(['new-task'], mode: 'renew', tagGroups: '1', err: err),
        exitBadUsage);
    expect(err.toString(), contains('原片'));
    expect(consumeAgentRequest(dataDir: dir, taskId: globalPresenceSlot),
        isNull, reason: '连单都不该下');
  });

  test('一个标签组都没给：拒绝并说清后果', () async {
    final err = StringBuffer();
    expect(await run(['new-task'], mode: 'script', err: err), exitBadUsage);
    expect(err.toString(), contains('标签组'));
  });

  test('mode 认不出时列出可选的三条线', () async {
    final err = StringBuffer();
    expect(await run(['new-task'], mode: '随便写', tagGroups: '1', err: err),
        exitBadUsage);
    expect(err.toString(), contains('script'));
    expect(err.toString(), contains('renew'));
    expect(err.toString(), contains('blank'));
  });

  test('参数合格：下单给界面，并把要建什么说清楚', () async {
    final err = StringBuffer();
    final f = Future(() => run(['new-task'],
        mode: 'script', tagGroups: '1261,1262', err: err));
    // 扮演界面：取单
    AgentRequest? got;
    for (var i = 0; i < 40 && got == null; i++) {
      got = consumeAgentRequest(dataDir: dir, taskId: globalPresenceSlot);
      if (got == null) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(got, isNotNull);
    expect(got!.kind, 'wizard.open');
    expect(got.payload['mode'], 'script');
    expect(got.payload['tagGroupIds'], [1261, 1262]);
    await f;
  });

  test('界面没回应：报失败，不能报成功——人会以为任务建好了', () async {
    final err = StringBuffer();
    expect(await run(['new-task'], mode: 'script', tagGroups: '1', err: err),
        isNot(0));
    expect(err.toString(), contains('没有回应'));
  });

  test('界面说没建成，原因原样带回来', () async {
    final err = StringBuffer();
    final f = Future(() => run(['new-task'],
        mode: 'script', tagGroups: '1', err: err,
        wait: const Duration(seconds: 2)));
    for (var i = 0; i < 60; i++) {
      final req = consumeAgentRequest(dataDir: dir, taskId: globalPresenceSlot);
      if (req != null) {
        writeAgentRequestResult(
            dataDir: dir, taskId: globalPresenceSlot, id: req.id,
            ok: false, message: '人把向导关掉了');
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await f, isNot(0));
    expect(err.toString(), contains('人把向导关掉了'));
  });

  test('认不出的子命令给用法', () async {
    final err = StringBuffer();
    expect(await run(['乱写'], err: err), exitBadUsage);
    expect(err.toString(), contains('new-task'));
  });
}
