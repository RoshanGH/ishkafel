import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/agent_stage.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';

/// 两种模式不是技术开关，是两种使用场景：
/// 静默 = 人不在场，跑完看结果；可视 = 人站在旁边看着它干活。
void main() {
  late Directory dir;
  final launched = <List<String>>[];

  setUp(() async {
    launched.clear();
    dir = await Directory.systemTemp.createTemp('stage');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<ProcessResult> fakeOpen(String exe, List<String> args) async {
    launched.add([exe, ...args]);
    return ProcessResult(1, 0, '', '');
  }

  AgentStage stage(AgentStageMode mode) => AgentStage(
        mode: mode,
        dataDir: dir,
        taskId: 't1',
        stepTimeout: const Duration(milliseconds: 120),
        run: fakeOpen,
      );

  test('静默模式：不弹窗、不写在场状态——那条路径要保持原来的速度', () async {
    await stage(AgentStageMode.silent).begin('挑镜头');
    expect(launched, isEmpty);
    expect(readAgentPresence(dataDir: dir, taskId: 't1'), isNull);
  });

  test('可视模式：把软件拉起来，并让它落到这个任务上', () async {
    await stage(AgentStageMode.visual).begin('挑镜头');
    expect(launched.single.join(' '), contains('open -a'));
    // 「去哪个任务」走唤醒文件而不是启动参数——app 已经在跑时启动参数
    // 会被静默丢弃（open 命令那边真机撞到过）
    expect(File('${dir.path}/ui_wake.json').existsSync(), isTrue,
        reason: '冷启动、热启动要走同一条路');
  });

  test('可视模式：每一步都说清在做什么、界面该看哪儿', () async {
    final s = stage(AgentStageMode.visual);
    await s.begin('开工');
    await s.show('正在给第 10 句挑镜头',
        focus: const AgentFocus(
            module: 'director', lineIndex: 9, panel: AgentPanel.findShots));
    final p = readAgentPresence(dataDir: dir, taskId: 't1')!;
    expect(p.action, '正在给第 10 句挑镜头');
    expect(p.focus!.module, 'director');
    expect(p.focus!.panel, AgentPanel.findShots);
    expect(p.step, greaterThan(1), reason: '步号要递增，界面按它回执');
  });

  test('界面回执了就立刻往下走，不白等', () async {
    final s = stage(AgentStageMode.visual);
    // 界面很快就展示完（每一步都马上回执）
    unawaited(() async {
      for (var i = 1; i <= 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        writeAgentAck(dataDir: dir, taskId: 't1', step: i);
      }
    }());
    final watch = Stopwatch()..start();
    await s.begin('开工');
    await s.show('第二步');
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(200),
        reason: '界面跟得上就别拖着——节奏由界面决定，不是猜时间');
  });

  test('界面没开：等一下就照常往下跑，不把正事卡死', () async {
    final s = stage(AgentStageMode.visual);
    final watch = Stopwatch()..start();
    await s.begin('开工'); // 没人回执
    watch.stop();
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(100));
    expect(readAgentPresence(dataDir: dir, taskId: 't1'), isNotNull,
        reason: '状态还是要写——万一界面晚一点开起来，它能看到');
  });

  test('收工：在场状态与回执都撤掉，人立刻能动手', () async {
    final s = stage(AgentStageMode.visual);
    await s.begin('开工');
    s.end();
    expect(readAgentPresence(dataDir: dir, taskId: 't1'), isNull);
    expect(readAgentAck(dataDir: dir, taskId: 't1'), -1);
  });

  test('模式可以由环境变量给——Agent 把它贯穿整个会话', () {
    expect(AgentStageMode.from(env: {'ISHKAFEL_VISUAL': '1'}),
        AgentStageMode.visual);
    expect(AgentStageMode.from(env: const {}), AgentStageMode.silent);
  });
}

void unawaited(Future<void> f) {}
