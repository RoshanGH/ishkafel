import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/features/agent/app_busy_holder.dart';

/// 「软件自己在忙」这份状态要替调用方管住两件事，散着写都会出岔子。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('busyholder'));
  tearDown(() => dir.deleteSync(recursive: true));

  AppBusyHolder holderOf({Duration pulse = const Duration(seconds: 20)}) =>
      AppBusyHolder(
          dataDir: dir,
          taskId: 't1',
          holder: '软件（编导台）',
          pulseEvery: pulse);

  bool present() => readAppBusy(dataDir: dir, taskId: 't1') != null;

  test('开工就挂上，收工就撤掉', () {
    final h = holderOf();
    final done = h.enter('正在配音');
    expect(present(), isTrue);
    expect(readAppBusy(dataDir: dir, taskId: 't1')!.action, '正在配音');
    done();
    expect(present(), isFalse);
    h.dispose();
  });

  /// **这一条是它存在的主要理由。**
  ///
  /// 批量活儿逐句 `写→撤` 之间是有缝的——那一瞬 `.app.json` 不存在，
  /// Agent 的 `script voice` 正好在缝里起来就不会被劝退，整轮双份计费。
  test('套着用：里层退出的那一瞬，状态一秒都不许消失', () {
    final h = holderOf();
    final outer = h.enter('正在配音（自动铺一版）');

    for (var i = 1; i <= 3; i++) {
      final inner = h.enter('正在给第 $i 句配音');
      expect(present(), isTrue);
      inner();
      // **就是这一刻**：里层退了、外层还在，状态必须还挂着
      expect(present(), isTrue,
          reason: '第 $i 句和第 ${i + 1} 句之间这道缝，够 Agent 的 '
              'script voice 从里面溜进来，整轮双份计费');
      expect(readAppBusy(dataDir: dir, taskId: 't1')!.action,
          '正在配音（自动铺一版）',
          reason: '里层退了要把话换回外层那句，不能留着上一句的');
    }

    outer();
    expect(present(), isFalse, reason: '最外层退了才真的撤');
    h.dispose();
  });

  test('心跳：中间一句话都不换，状态也不会过期', () async {
    final h = holderOf(pulse: const Duration(milliseconds: 30));
    final done = h.enter('正在分析原片');
    final first = readAppBusy(dataDir: dir, taskId: 't1')!.at;

    await Future<void>.delayed(const Duration(milliseconds: 150));

    final later = readAppBusy(dataDir: dir, taskId: 't1')!;
    expect(later.at.isAfter(first), isTrue,
        reason: '没有心跳的话，60 秒后这份状态就过期了——'
            '而一句 TTS、一镜识图常常超过它');
    expect(later.action, '正在分析原片', reason: '心跳原样重发，不换话');

    done();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(present(), isFalse, reason: '收工没停掉心跳的话，撤下去的会被写回来');
    h.dispose();
  });

  test('同一个收工回调调两次是安全的——调用方不必自己记状态', () {
    final h = holderOf();
    final outer = h.enter('外层');
    final inner = h.enter('里层');
    inner();
    inner();
    expect(present(), isTrue, reason: '重复调不该把外层那层也退掉');
    outer();
    expect(present(), isFalse);
    h.dispose();
  });

  /// **交叉释放不许让话变空。**
  ///
  /// 一度用「进场时拍快照、退场还原」：两层交叉释放时，先释放那个会把话
  /// 还原成它进场时的空串——`.app.json` 还在、`action` 却成了空串，
  /// `busy_guard` 的关键词匹配当场失配。**状态还在、劝告已经瞎了**，
  /// 比文件消失更难发现。
  test('交叉释放：话换成栈里剩下那一层的，绝不变空', () {
    final h = holderOf();
    final a = h.enter('正在配音（整轮）');
    final b = h.enter('正在给第 3 句配音');

    a(); // 先放外层——快照还原那版会在这一下把话抹成空串
    expect(present(), isTrue);
    final action = readAppBusy(dataDir: dir, taskId: 't1')!.action;
    expect(action, isNotEmpty, reason: '话一空，判据的关键词匹配就失配了');
    expect(action, '正在给第 3 句配音', reason: '该是栈里剩下那一层的话');

    b();
    expect(present(), isFalse);
    h.dispose();
  });

  /// `dispose()` 之后遗留的收工回调不许再动这份状态。
  ///
  /// 不作废的话：计数被减成负数，此后 enter/exit 配对全乱；而多出来的那一次
  /// 收工会 `clearAppBusy`——**这份文件有第二个写入方**（任务列表那边的
  /// 分析），于是一个已经销毁的页面可能抹掉别人正在跑的活儿的状态。
  test('dispose 之后的遗留回调：什么都不做，尤其不许去撤别人的状态', () {
    final h = holderOf();
    final stale = h.enter('这一页的活儿');
    h.dispose();
    expect(present(), isFalse);

    // 另一边（比如任务列表的分析）挂上了自己的
    final other = holderOf();
    final otherDone = other.enter('正在分析原片');
    expect(present(), isTrue);

    stale(); // 上一代的回调回来了
    stale();
    expect(present(), isTrue,
        reason: '已经销毁的页面把别人正在跑的活儿的状态抹掉了');
    expect(h.depth, 0, reason: '计数不许被减成负数');
    expect(readAppBusy(dataDir: dir, taskId: 't1')!.action, '正在分析原片');

    otherDone();
    other.dispose();
  });

  test('页面拆了：嵌套到第几层都收干净', () async {
    final h = holderOf(pulse: const Duration(milliseconds: 20));
    h.enter('外层');
    h.enter('里层');
    h.dispose();
    expect(present(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(present(), isFalse, reason: 'Timer 没停的话它会把状态写回来');
  });
}
