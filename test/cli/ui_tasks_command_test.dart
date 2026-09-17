import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/ui_command.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/agent_request.dart';

/// `ishkafel ui tasks` —— 让界面退回任务列表，松开它占着的写锁。
///
/// **委派降级成首选路径 + 秒级兜底**（2026-09-17 第一批 任务 8）：以前
/// 界面没回应就报 `exitEnv`——而这条命令本来就是在**界面可能根本不在**
/// 的前提下发的（“它可能没开——那样也就没有锁挡着”，代码自己的注释
/// 早就这么说），报失败反而不对。没回应不是失败：它没开，或者没在
/// 监听这个请求，两种情形下都没有锁真的挡着后续写操作——那些命令撞锁
/// 会自己请界面让位或直接落盘，不需要这一步先等出一个结果。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ui_tasks_cmd_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int> run({StringSink? out, StringSink? err, Duration? wait}) =>
      runUiCommand(
        rest: const ['tasks'],
        dataDir: dir,
        env: const {},
        appExists: (_) => true,
        waitForUi: wait ?? const Duration(milliseconds: 300),
        out: out,
        err: err,
        run: (bin, args) async =>
            bin == 'pgrep'
                ? ProcessResult(0, 1, '', '')
                : ProcessResult(0, 0, '', ''),
      );

  test('界面没回应：不再报 exitEnv，照常返回 0 并说清没等它', () async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await run(out: out, err: err);
    expect(code, 0, reason: '界面可能压根没开，而这一步本来就不影响任何事');
    expect(err.toString(), contains('界面没接这一单'));
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['ok'], isTrue);
    expect(json['via'], 'agent');
    expect(json['landed'], isFalse, reason: '老实说没等到界面的确认');
  });

  test('界面真的回应了：照常报 via ui', () async {
    final out = StringBuffer();
    final f = Future(() => run(out: out, wait: const Duration(seconds: 2)));
    for (var i = 0; i < 60; i++) {
      final req = consumeAgentRequest(dataDir: dir, taskId: globalPresenceSlot);
      if (req != null) {
        writeAgentRequestResult(
            dataDir: dir, taskId: globalPresenceSlot, id: req.id,
            ok: true, message: '已回到任务列表，锁松开了');
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await f, 0);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['via'], 'ui');
    expect(json['message'], contains('松开'));
  });
}
