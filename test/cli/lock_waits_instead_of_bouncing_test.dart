import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/lock_yield.dart';
import 'package:ishkafel/core/storage/task_lock.dart';

/// **锁不该把活儿挡在门外。**
///
/// 用户的原话：「他开不开可视化都不该有什么锁挡住执行，还说自己在等待。」
///
/// 真机上发生的事：`script voice` 要跑几分钟 25 句 TTS，调用方的命令超时了，
/// 它以为失败就再起一个；第二个撞上第一个的锁，于是报告
/// 「我会等待锁释放后自动续跑」——**它在等它自己**，来回好几轮。
/// 而配音其实早就 25/25 全好了。
///
/// 锁的本意只是防止两个写入方同时改坏同一份数据，不是让调用方原地放弃。
/// 占着的那个进程还活着，就等它；等的时候要**出声**，否则一条命令挂在
/// 那儿不动，看起来就是卡死。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('lockwait'));
  tearDown(() => dir.deleteSync(recursive: true));

  TaskLockFile lockFor(String holder, {bool Function(int)? alive}) =>
      TaskLockFile(
          dataDir: dir,
          taskId: 't1',
          processAlive: alive ?? (_) => true);

  test('没人占着：直接拿到', () async {
    final ok = await acquireYieldingFromUi(
      lock: lockFor('agent:1'),
      holder: 'agent:1',
      dataDir: dir,
      taskId: 't1',
    );
    expect(ok, isTrue);
  });

  test('占锁的进程已经没了：直接接管，不用等', () async {
    lockFor('agent:999').acquire('agent:999');
    final ok = await acquireYieldingFromUi(
      // 那个 pid 查不到了
      lock: lockFor('agent:2', alive: (_) => false),
      holder: 'agent:2',
      dataDir: dir,
      taskId: 't1',
      waitForAgent: const Duration(milliseconds: 200),
    );
    expect(ok, isTrue, reason: '进程都没了还占着锁，等它是等不到的');
  });

  test('另一个进程还在跑：等它，而且要出声说在等', () async {
    lockFor('agent:87821').acquire('agent:87821');
    final said = <String>[];
    final ok = await acquireYieldingFromUi(
      lock: lockFor('agent:2'),
      holder: 'agent:2',
      dataDir: dir,
      taskId: 't1',
      waitForAgent: const Duration(milliseconds: 300),
      pollEvery: const Duration(milliseconds: 50),
      onWait: said.add,
    );
    expect(ok, isFalse, reason: '这一轮里对方一直没放手');
    expect(said, isNotEmpty,
        reason: '等的时候一声不吭，看起来就是命令卡死了');
    expect(said.first, contains('不是卡住'),
        reason: '要明说「在等它干完」，别让人以为出了故障');
    expect(said.first, contains('别再起一个'),
        reason: '真机上它就是又起了一个，然后等自己');
  });

  test('对方干完放手了：接着往下走', () async {
    final other = lockFor('agent:3');
    other.acquire('agent:3');
    // 一小会儿之后它干完了
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      other.release('agent:3');
    });
    final ok = await acquireYieldingFromUi(
      lock: lockFor('agent:4'),
      holder: 'agent:4',
      dataDir: dir,
      taskId: 't1',
      waitForAgent: const Duration(seconds: 3),
      pollEvery: const Duration(milliseconds: 20),
    );
    expect(ok, isTrue, reason: '等到了就该继续，这正是「等它」的意义');
  });

  test('界面留下的锁、而界面已不在那一页：直接接管，绝不干等', () async {
    lockFor('人（编导台）').acquire('人（编导台）');
    final said = <String>[];
    final started = DateTime.now();
    final ok = await acquireYieldingFromUi(
      lock: lockFor('agent:5'),
      holder: 'agent:5',
      dataDir: dir,
      taskId: 't1',
      // 界面根本不存在，这个请求没人接
      waitForUi: const Duration(milliseconds: 100),
      waitForAgent: const Duration(minutes: 20),
      onWait: said.add,
    );
    expect(ok, isTrue,
        reason: '界面的锁不会自己放。落进「等它干完」的循环就是等到天荒地老'
            '——真机上人看到的是每条命令一开始就卡死，比原来一撞就退还糟');
    expect(DateTime.now().difference(started).inSeconds, lessThan(5),
        reason: '这一步必须是快的');
    expect(said.join(), contains('直接接管'));
  });
}
