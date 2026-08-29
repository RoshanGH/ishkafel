import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/agent_lock_holder.dart';
import 'package:ishkafel/core/storage/task_lock.dart';

/// 锁失效有两条判据：心跳超时（60 秒），以及**写锁的进程还在不在**。
/// 后者能让人在 Agent 崩掉后立刻接手，不用干等一分钟。
///
/// 但它要靠持有者名字里的 pid 才认得出来——而 CLI 一直写死成 `agent`，
/// 不带 pid，于是这条快捷判据对 Agent 的锁完全无效（真机自查发现：
/// 命令被杀之后锁还躺着，只能等心跳超时）。
void main() {
  test('Agent 的持有者名带 pid，进程没了才认得出来', () {
    expect(agentLockHolder, matches(RegExp(r'^agent:\d+$')));
  });

  test('这个名字能被锁的进程检查解析出来', () {
    final lock = TaskLock(
      holder: agentLockHolder,
      acquiredAt: DateTime(2026),
      heartbeatAt: DateTime(2026),
    );

    expect(lock.holderPid, isNotNull);
    // 进程不在了就立刻失效，不用等心跳超时
    expect(
        lock.isStale(DateTime(2026), processAlive: (_) => false), isTrue);
    expect(lock.isStale(DateTime(2026), processAlive: (_) => true), isFalse);
  });

  test('界面那头认得出这是 Agent 不是人', () {
    expect(isGuiHolder(agentLockHolder), isFalse,
        reason: '认错的话，Agent 占着锁时界面会以为「人在编辑」，'
            '给出的引导就全错了');
  });

  test('CLI 里不许再写死不带 pid 的持有者名', () {
    final offenders = <String>[];
    for (final f in Directory('lib/cli')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final line in src.split('\n')) {
        if (line.trimLeft().startsWith('//')) continue;
        // 占锁用的名字必须带 pid；AgentStage 那个是显示给人看的横幅名，
        // 不是锁，所以只查跟 lock 有关的行
        if (!RegExp(r'(acquire|heartbeat|release|forceTakeover)\(').hasMatch(line)) {
          continue;
        }
        if (RegExp("'[Aa]gent'").hasMatch(line)) {
          offenders.add('${f.path}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: '这些地方占锁用的名字不带 pid，进程没了也认不出来：\n'
            '${offenders.join('\n')}');
  });

}
