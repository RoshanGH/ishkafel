import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';

/// 可视模式的节奏**不能靠猜时间**：Agent 发出一步，界面真的展示完
/// （滚动停下、面板展开）才回执，Agent 收到才走下一步。
/// 界面没开、崩了、关了窗口——都不能让 Agent 永远等下去。
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('handshake'));
  tearDown(() => dir.delete(recursive: true));

  AgentPresence step(int n, {String action = '干活'}) => AgentPresence(
        holder: 'Agent',
        at: DateTime.now(),
        action: action,
        step: n,
        focus: const AgentFocus(
            module: 'director', lineIndex: 9, panel: AgentPanel.shot),
      );

  test('每一步带序号，界面按序号回执', () {
    writeAgentPresence(dataDir: dir, taskId: 't1', presence: step(3));
    expect(readAgentPresence(dataDir: dir, taskId: 't1')!.step, 3);

    writeAgentAck(dataDir: dir, taskId: 't1', step: 3);
    expect(readAgentAck(dataDir: dir, taskId: 't1'), 3);
  });

  test('焦点要能说清去哪个模块——不是只有编导台', () {
    writeAgentPresence(
      dataDir: dir,
      taskId: 't1',
      presence: AgentPresence(
        holder: 'Agent',
        at: DateTime.now(),
        action: '看候选',
        step: 1,
        focus: const AgentFocus(module: 'workbench', unitIndex: 3),
      ),
    );
    final f = readAgentPresence(dataDir: dir, taskId: 't1')!.focus!;
    expect(f.module, 'workbench');
    expect(f.unitIndex, 3);
  });

  test('等回执：界面回了就立刻往下走', () async {
    writeAgentPresence(dataDir: dir, taskId: 't1', presence: step(1));
    // 界面 50ms 后展示完
    unawaited(Future<void>.delayed(const Duration(milliseconds: 50),
        () => writeAgentAck(dataDir: dir, taskId: 't1', step: 1)));
    final waited = await waitForAck(
        dataDir: dir,
        taskId: 't1',
        step: 1,
        timeout: const Duration(seconds: 2));
    expect(waited, isTrue);
  });

  test('界面没开就别傻等——超时后照样往下跑', () async {
    writeAgentPresence(dataDir: dir, taskId: 't1', presence: step(1));
    final waited = await waitForAck(
        dataDir: dir,
        taskId: 't1',
        step: 1,
        timeout: const Duration(milliseconds: 120));
    expect(waited, isFalse, reason: '界面没开、崩了、被关了都不能把 Agent 卡死');
  });

  test('回执落后于当前步：继续等，别把旧回执当成新的', () async {
    writeAgentAck(dataDir: dir, taskId: 't1', step: 1);
    writeAgentPresence(dataDir: dir, taskId: 't1', presence: step(2));
    final waited = await waitForAck(
        dataDir: dir,
        taskId: 't1',
        step: 2,
        timeout: const Duration(milliseconds: 120));
    expect(waited, isFalse);
  });
}

