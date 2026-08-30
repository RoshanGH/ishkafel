import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/agent_broadcast.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/features/workbench/serve_broadcast.dart';

/// 委派提交方案时，**过程是无声的**——验收 Agent 用 0.3 秒密拍 40 帧，
/// 逐帧比对：没有任何一帧出现过播报条。
///
/// 而 CLI 那头打印的是「已请界面代为提交——**人能看着方案落进去**」。
/// 那是一句还没兑现的话：结果可见（右上角数字从 3 跳到 6），过程无声。
///
/// 这一步恰恰最需要说话：它决定成片长什么样，而且是 Agent 判断最密集的
/// 一步（34 镜 × N 条方案，每一条都是它选的）。人焦虑的正是这个。
void main() {
  _warningTests();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('serve'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('界面代办时自己报在场——播报条读的就是它', () {
    final voice = ServeBroadcast(dataDir: dir, taskId: 't1');

    voice.say('正在提交 2 条方案');

    final p = readAgentPresence(dataDir: dir, taskId: 't1');
    expect(p?.action, '正在提交 2 条方案');
    expect(p?.holder, 'Agent', reason: '活儿是 Agent 请托的，署名要一致——'
        '写成「界面」的话，人会以为是自己点的');
  });

  test('一步步说，步号递增（播报条据此判断是不是新一步）', () {
    final voice = ServeBroadcast(dataDir: dir, taskId: 't1');

    voice.say('正在核对方案');
    final first = readAgentPresence(dataDir: dir, taskId: 't1')!.step;
    voice.say('正在投影到时间线');
    final second = readAgentPresence(dataDir: dir, taskId: 't1')!.step;

    expect(second, greaterThan(first));
  });

  test('干完撤场——不撤的话界面永远停在只读态', () {
    final voice = ServeBroadcast(dataDir: dir, taskId: 't1');
    voice.say('正在提交');

    voice.done();

    expect(readAgentPresence(dataDir: dir, taskId: 't1'), isNull);
  });
}

/// 界面代办时发现「会毁掉整片」的问题，得**当场说出来**。
///
/// 不说的话，人看到的是「一切正常，方案落好了」——而烧着别家字幕、
/// 露着竞品的素材只有看图才发现得了，指望他自己去托盘上一条条翻是不现实的。
void _warningTests() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('serve_warn'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('发现问题时报的是 warning 类，不混在流水账里', () async {
    final voice = ServeBroadcast(dataDir: dir, taskId: 't1');

    await voice.warnAndHold('有 2 条素材画面上烧着字，成片会出现两层字幕');

    final p = readAgentPresence(dataDir: dir, taskId: 't1')!;
    expect(p.kind, BroadcastKind.warning);
    expect(p.action, contains('两层字幕'));
  });

  test('普通一步仍然是进度类——绝大多数播报都是它', () {
    final voice = ServeBroadcast(dataDir: dir, taskId: 't1');
    voice.say('正在投影到时间线');
    expect(readAgentPresence(dataDir: dir, taskId: 't1')!.kind,
        BroadcastKind.step);
  });

  test('警告要停得比普通一步久——这一条值得人多看两眼', () async {
    final voice = ServeBroadcast(dataDir: dir, taskId: 't1');
    final t0 = DateTime.now();
    await voice.warnAndHold('画面里露的是别家的产品');
    final warned = DateTime.now().difference(t0);

    final t1 = DateTime.now();
    await voice.sayAndHold('接着往下走');
    final normal = DateTime.now().difference(t1);

    expect(warned, greaterThan(normal));
  });
}
