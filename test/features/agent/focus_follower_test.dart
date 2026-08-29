import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/features/agent/focus_follower.dart';

/// 可视化模式是**做给人看的**，不是给 Agent 加进度日志。
///
/// 用户的话：「它解决了大家在使用时候的焦虑问题，也只有在几次可视化的模式下
/// 觉得没问题了，才会有人愿意让你在静默模式下去操作」——这些操作都要花钱，
/// 人得先在旁边看着它安稳跑过很多次。
///
/// 所以判据不是「状态打出来了没有」，而是**界面有没有像人操作那样动起来**：
/// Agent 说它在看 U3S2，界面就该选中 U3、选中 S2、右侧切到候选面板。
/// `AgentFocus` 里这些字段早就定义好了，但界面一个文件都没读过它。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('focus'));
  tearDown(() => dir.deleteSync(recursive: true));

  var step = 0;
  void write(AgentFocus focus, {String action = '正在挑素材'}) =>
      writeAgentPresence(
        dataDir: dir,
        taskId: 't1',
        presence: AgentPresence(
          holder: 'Agent',
          at: DateTime.now(),
          action: action,
          focus: focus,
          step: ++step,
        ),
      );

  test('Agent 在看哪个单元哪一镜，界面就跟到哪儿', () {
    write(const AgentFocus(
        module: 'workbench', unitIndex: 3, shotIndex: 2,
        panel: AgentPanel.findShots));

    final step = readFocusStep(dataDir: dir, taskId: 't1');

    expect(step, isNotNull);
    expect(step!.unitIndex, 3);
    expect(step.shotIndex, 2);
    expect(step.panel, AgentPanel.findShots);
    expect(step.action, '正在挑素材');
  });

  test('Agent 不在场时不跟——人自己在操作，界面别自作主张乱跳', () {
    expect(readFocusStep(dataDir: dir, taskId: 't1'), isNull);
  });

  test('心跳停了就当它走了：不能让界面永远锁在最后一个位置上', () {
    write(const AgentFocus(module: 'workbench', unitIndex: 1));

    final step = readFocusStep(
        dataDir: dir,
        taskId: 't1',
        now: DateTime.now().add(const Duration(minutes: 5)));

    expect(step, isNull);
  });

  test('同一个位置重复上报不算新一步——界面别反复重建', () {
    write(const AgentFocus(module: 'workbench', unitIndex: 3, shotIndex: 2));
    final first = readFocusStep(dataDir: dir, taskId: 't1')!;

    write(const AgentFocus(module: 'workbench', unitIndex: 3, shotIndex: 2));
    final second = readFocusStep(dataDir: dir, taskId: 't1')!;

    expect(second.sameSpotAs(first), isTrue);
  });

  test('换了镜头就是新一步', () {
    write(const AgentFocus(module: 'workbench', unitIndex: 3, shotIndex: 2));
    final first = readFocusStep(dataDir: dir, taskId: 't1')!;

    write(const AgentFocus(module: 'workbench', unitIndex: 3, shotIndex: 5));
    final second = readFocusStep(dataDir: dir, taskId: 't1')!;

    expect(second.sameSpotAs(first), isFalse);
  });

  test('人眼要跟得上：每一步至少停这么久', () {
    // 值先定在这儿，后面按真机观感调——重点是有这么个下限
    expect(focusStepMinDwell.inMilliseconds, greaterThanOrEqualTo(500));
  });
}
