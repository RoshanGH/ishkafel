import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/agent_request.dart';

/// `ui new-task` 报出来的任务 id 一直是**猜的**：建完之后去任务库里
/// 翻「创建时间最新的那条」。代码注释自己都写着「不给的话只能去 tasks 里
/// 翻最后一条猜」——而它做的正是猜。
///
/// 真机后果（验收 Agent 撞到）：macOS 弹了「想访问文稿文件夹」的授权框，
/// 没人点允许，任务压根没建成——CLI 却把**上一次**建的任务报了出来，
/// 还带着 `ok:true`「任务已经建好了」。人照着那个 id 往下走，
/// 操作的是另一条任务。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('req'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('界面回执能带上它真正建出来的 id', () async {
    writeAgentRequestResult(
      dataDir: dir,
      taskId: globalPresenceSlot,
      result: const AgentRequestResult(
        id: 'r1',
        ok: true,
        message: '任务已经建好了',
        payload: {'taskId': 'hlnew123', 'kind': 'replace'},
      ),
    );

    final got = await waitForAgentRequest(
        dataDir: dir,
        taskId: globalPresenceSlot,
        id: 'r1',
        timeout: const Duration(seconds: 2));

    expect(got?.payload['taskId'], 'hlnew123');
    expect(got?.payload['kind'], 'replace');
  });

  test('老的回执没有 payload 也读得动——不能因为多个字段就读不回来', () async {
    File('${dir.path}/presence/$globalPresenceSlot.request-result.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"id":"r2","ok":true,"message":"好了"}');

    final got = await waitForAgentRequest(
        dataDir: dir,
        taskId: globalPresenceSlot,
        id: 'r2',
        timeout: const Duration(seconds: 2));

    expect(got?.ok, isTrue);
    expect(got?.payload, isEmpty);
  });
}
