import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/agent_request.dart';

/// Agent 请界面**代办**一件事。
///
/// 与在场状态（Agent → 界面「我在做什么」）方向相同、语义相反：那是通报，
/// 这是请求。存在理由：人正开着审片台看着指挥它时，剔除还只是界面里的
/// 临时状态（人按确认才落盘）——Agent 这时自己写盘，人还没确认盘上就变了。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('agent_request_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('写了就能读到，读到即删——同一条请求只执行一次', () {
    final id = writeAgentRequest(
      dataDir: dir,
      taskId: 't1',
      kind: 'review.drop',
      payload: const {
        'decisions': [
          {'unit': 0, 'shot': null, 'material': 100, 'keep': false}
        ]
      },
    );
    final got = consumeAgentRequest(dataDir: dir, taskId: 't1');
    expect(got, isNotNull);
    expect(got!.id, id);
    expect(got.kind, 'review.drop');
    expect((got.payload['decisions'] as List), hasLength(1));
    expect(consumeAgentRequest(dataDir: dir, taskId: 't1'), isNull);
  });

  test('没有请求时读到 null，不炸', () {
    expect(consumeAgentRequest(dataDir: dir, taskId: 't1'), isNull);
  });

  test('文件坏了当作没有——一条读不懂的请求不该把界面卡住', () {
    final f = File('${dir.path}/presence/t1.request.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{不是 json');
    expect(consumeAgentRequest(dataDir: dir, taskId: 't1'), isNull);
    expect(f.existsSync(), isFalse, reason: '坏文件也要清掉，不然每轮都重读');
  });

  test('界面回执按 id 配对，Agent 等到才算数', () async {
    final id = writeAgentRequest(
        dataDir: dir, taskId: 't1', kind: 'review.drop', payload: const {});
    writeAgentRequestResult(
        dataDir: dir, taskId: 't1', id: id, ok: true, message: '已标记 2 条');
    final result = await waitForAgentRequest(
        dataDir: dir, taskId: 't1', id: id,
        timeout: const Duration(seconds: 1));
    expect(result, isNotNull);
    expect(result!.ok, isTrue);
    expect(result.message, '已标记 2 条');
  });

  test('回执 id 对不上就继续等——不能把上一轮的回执当成这一轮的', () async {
    writeAgentRequestResult(
        dataDir: dir, taskId: 't1', id: '上一轮', ok: true, message: '');
    final result = await waitForAgentRequest(
        dataDir: dir, taskId: 't1', id: '这一轮',
        timeout: const Duration(milliseconds: 200));
    expect(result, isNull);
  });

  test('界面没接就超时返回 null——这里的超时是真失败，活儿没干', () async {
    final result = await waitForAgentRequest(
        dataDir: dir, taskId: 't1', id: 'x',
        timeout: const Duration(milliseconds: 150));
    expect(result, isNull);
  });

  test('界面报失败也要如实带回原因', () async {
    writeAgentRequestResult(
        dataDir: dir, taskId: 't1', id: 'x', ok: false, message: '没有这张卡');
    final result = await waitForAgentRequest(
        dataDir: dir, taskId: 't1', id: 'x',
        timeout: const Duration(seconds: 1));
    expect(result!.ok, isFalse);
    expect(result.message, '没有这张卡');
  });
}
