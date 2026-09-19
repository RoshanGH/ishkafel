import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/busy_guard.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';

/// **软件自己跑的活儿和 Agent 的活儿，分两条通道。**
///
/// CLAUDE.md 明令：「播报只报 Agent 在做什么。软件自己跑的活儿不许占那条
/// 通道——占了，人就分不清是谁在动手。」
///
/// 但**「别把同一件贵活儿跑两遍」那道劝告必须两份都看**：它存在的理由之一
/// 就是拦住「人在界面上点了分析 + Agent 同时 analyze」。分开通道是为了不让
/// 软件占播报，**不是为了让判据装作看不见它**——那是这条最容易做错的地方。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('appbusy'));
  tearDown(() => dir.deleteSync(recursive: true));

  AgentPresence busy(String action, {String holder = '软件（分析）'}) =>
      AgentPresence(holder: holder, at: DateTime.now(), action: action);

  test('软件在忙不出现在 Agent 的播报通道上', () {
    writeAppBusy(dataDir: dir, taskId: 't1', busy: busy('正在分析原片'));

    expect(readAgentPresence(dataDir: dir, taskId: 't1'), isNull,
        reason: '播报层扫的就是这一份——软件自己跑的活儿占了它，'
            '底部浮层就会冒出「软件（分析）正在干 #12」+ 转圈，'
            '跟 Agent 干活长得一模一样');
    expect(readAppBusy(dataDir: dir, taskId: 't1'), isNotNull);
  });

  test('但劝告的判据看得见它——不然这道劝告等于白加', () {
    writeAppBusy(dataDir: dir, taskId: 't1', busy: busy('正在分析原片'));

    final seen = someoneElseBusyWith(
        dataDir: dir, taskId: 't1', keywords: const [analyzeBusyKeyword]);
    expect(seen, isNotNull,
        reason: '人在界面上点了分析、Agent 同时 analyze，'
            '整条管线（几分钟、按量计费）会跑两遍');
    expect(seen!.holder, '软件（分析）', reason: '要说得出是谁在做');
  });

  test('两边互不覆盖：软件开工不会抹掉正在跑的 Agent 的在场状态', () {
    writeAgentPresence(
      dataDir: dir,
      taskId: 't1',
      presence: busy('正在给第 12 句配音', holder: 'Agent'),
    );
    writeAppBusy(dataDir: dir, taskId: 't1', busy: busy('正在分析原片'));

    final agent = readAgentPresence(dataDir: dir, taskId: 't1');
    expect(agent?.holder, 'Agent',
        reason: '共用一个文件的话，人点一下重试分析就把 Agent 的状态盖掉了');
    expect(agent?.action, contains(voiceBusyKeyword));
  });

  test('两边互不覆盖：软件收工不会把 Agent 的一起抹掉', () {
    writeAgentPresence(
      dataDir: dir,
      taskId: 't1',
      presence: busy('正在给第 12 句配音', holder: 'Agent'),
    );
    writeAppBusy(dataDir: dir, taskId: 't1', busy: busy('正在分析原片'));

    clearAppBusy(dataDir: dir, taskId: 't1');

    expect(readAppBusy(dataDir: dir, taskId: 't1'), isNull);
    expect(readAgentPresence(dataDir: dir, taskId: 't1'), isNotNull,
        reason: '共用的话这一下会把对方的也抹掉：要等 20 秒心跳才自愈，'
            '而抹掉那一刻正开着编导台的人还会收到一次假的「Agent 的改动已载入」');
  });

  test('心跳停了就当它不在——软件崩了不能把这条任务永久劝退', () {
    writeAppBusy(
      dataDir: dir,
      taskId: 't1',
      busy: AgentPresence(
          holder: '软件（分析）',
          at: DateTime.now().subtract(defaultStaleAfter * 2),
          action: '正在分析原片'),
    );

    expect(readAppBusy(dataDir: dir, taskId: 't1'), isNull);
    expect(
        someoneElseBusyWith(
            dataDir: dir, taskId: 't1', keywords: const [analyzeBusyKeyword]),
        isNull);
  });
}
