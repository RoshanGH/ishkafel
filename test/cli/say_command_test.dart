import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/say_command.dart';
import 'package:ishkafel/core/storage/agent_broadcast.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';

import '../support/seed_task.dart';

/// `ishkafel say` —— **让 Agent 自己说话**。
///
/// 播报分三类（见 [BroadcastKind]），其中**判断类最值钱**：
/// 「标签命中 5318 条太宽，改用画面描述再搜一轮」——人肯把花钱的活交给
/// 静默模式，靠的正是看懂过它是怎么想的。
///
/// 这条命令存在的理由是 2026-09-20 真机测出来的一个洞：判断类播报**一个
/// 产生者都没有**。原先仅有的两处（标签收窄、结果太宽自动改走语义搜）
/// 是软件在替人判断，当天被整体拆掉了——拆得对，但拆完这一类就空了。
///
/// 正解不是把软件那句假判断放回去，而是**把话筒交给真正在判断的那个**：
/// 软件只报事实（命中多少条），要不要改主意、为什么改，由 Agent 自己说。
/// 这也是「人在界面上能拧的每个旋钮，Agent 都要能拧」漏掉的一个。
void main() {
  late Directory dataDir;
  setUp(() => dataDir = Directory.systemTemp.createTempSync('ishkafel_say'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  /// 测试里不能真等界面回执（默认 5 秒），给一个极短的超时
  Future<int> say(
    List<String> rest, {
    String? judgement,
    String? warning,
    String? step,
    int? unitIndex,
    int? shotIndex,
    int? lineIndex,
    bool visual = true,
    StringSink? err,
  }) =>
      runSayCommand(
        rest: rest,
        dataDir: dataDir,
        judgement: judgement,
        warning: warning,
        step: step,
        unitIndex: unitIndex,
        shotIndex: shotIndex,
        lineIndex: lineIndex,
        visual: visual,
        err: err,
        stepTimeout: const Duration(milliseconds: 5),
      );

  AgentPresence? presenceOf(String taskId) =>
      readAgentPresence(dataDir: dataDir, taskId: taskId);

  group('三类播报，Agent 都发得出来', () {
    test('--judgement 发的是判断类，原话一字不改', () async {
      final taskId = (await seedTask(dataDir)).id;

      final code = await say([taskId],
          judgement: '标签命中 518 条，太宽了，我改用画面描述再搜一轮');

      expect(code, 0);
      final p = presenceOf(taskId);
      expect(p, isNotNull);
      expect(p!.kind, BroadcastKind.judgement,
          reason: '判断类是三类里最值钱的一类，界面靠 kind 给它蓝色和灯泡');
      expect(p.action, '标签命中 518 条，太宽了，我改用画面描述再搜一轮',
          reason: '它说什么就播什么，软件不改写、不加前缀');
      expect(p.holder, 'Agent');
    });

    test('--warning 发的是发现问题类', () async {
      final taskId = (await seedTask(dataDir)).id;

      await say([taskId], warning: 'U2S1 这条素材右下角烧着别家的字，我换掉了');

      expect(presenceOf(taskId)!.kind, BroadcastKind.warning,
          reason: '橙色那一类：人可能要当场喊停，而且不会被后面的流水账挤掉');
    });

    test('--step 发的是进度类', () async {
      final taskId = (await seedTask(dataDir)).id;

      await say([taskId], step: '正在逐条看这 50 个候选的画面');

      expect(presenceOf(taskId)!.kind, BroadcastKind.step,
          reason: 'Agent 在两条命令之间自己干的慢活儿，也得有地方说');
    });
  });

  group('说给谁听、指哪儿看', () {
    test('不给任务就挂在全局槽上——它在整个软件上干活，不是在某一页', () async {
      final code = await say(const [], judgement: '这五条任务我先都看一眼');

      expect(code, 0);
      expect(presenceOf(globalPresenceSlot), isNotNull,
          reason: '播报是全局的：跨任务、跨模块都该看得见');
    });

    test('--unit/--shot 把界面指到那一镜', () async {
      final taskId = (await seedTask(dataDir)).id;

      await say([taskId],
          judgement: '这一镜前后连不上，我换一条', unitIndex: 2, shotIndex: 1);

      final focus = presenceOf(taskId)!.focus;
      expect(focus, isNotNull);
      expect(focus!.unitIndex, 2);
      expect(focus.shotIndex, 1);
      expect(focus.module, 'workbench',
          reason: '单元/镜头是工作台的坐标');
    });

    test('--line 指的是编导台那一行', () async {
      final taskId = (await seedTask(dataDir)).id;

      await say([taskId], judgement: '这一句的参考镜我看不懂，先跳过', lineIndex: 3);

      final focus = presenceOf(taskId)!.focus;
      expect(focus!.lineIndex, 3);
      expect(focus.module, 'director');
    });

    test('没指位置就只说话，不把界面拽走', () async {
      final taskId = (await seedTask(dataDir)).id;

      await say([taskId], judgement: '这条任务的素材整体偏暗');

      expect(presenceOf(taskId)!.focus, isNull,
          reason: '没话要指的时候硬指一个位置，界面会平白跳一下');
    });

    test('任务不存在就直说', () async {
      final err = StringBuffer();
      final code = await say(['没这条'], judgement: '随便说说', err: err);

      expect(code, exitNotFound);
      expect(err.toString(), contains('没这条'));
    });
  });

  group('参数不对要当场说清', () {
    test('一句话都没给', () async {
      final err = StringBuffer();
      final code = await say(const [], err: err);

      expect(code, exitBadUsage);
      expect(err.toString(), contains('--judgement'));
      expect(err.toString(), contains('--warning'));
      expect(err.toString(), contains('--step'));
    });

    test('一次只能说一句，给两个就说不清是哪一类', () async {
      final err = StringBuffer();
      final code =
          await say(const [], judgement: '甲', warning: '乙', err: err);

      expect(code, exitBadUsage);
      expect(err.toString(), contains('一次只说一句'));
    });

    test('空话不播', () async {
      final err = StringBuffer();
      final code = await say(const [], judgement: '   ', err: err);

      expect(code, exitBadUsage);
      expect(presenceOf(globalPresenceSlot), isNull);
    });
  });

  test('静默模式下没人在看——不播，但**要说出来**，不能静静地吞掉', () async {
    final taskId = (await seedTask(dataDir)).id;
    final err = StringBuffer();

    final code = await say([taskId],
        judgement: '标签太宽，我换个搜法', visual: false, err: err);

    expect(code, 0, reason: '这不是 Agent 做错了什么，不该给它一个失败');
    expect(presenceOf(taskId), isNull);
    expect(err.toString(), contains('--visual'),
        reason: '不说的话，它以为播出去了，而人那头什么都没看见——'
            '正是「静默降级」那个形状');
  });
}
