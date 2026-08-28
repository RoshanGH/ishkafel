import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/task_lock.dart';

/// Agent 在跑、人又打开了 GUI，两边都写同一份任务 JSON——后写的把先写的
/// 覆盖掉，而且悄无声息。这是真实的数据丢失，且**只有软件看得见两个写入方**，
/// 所以必须软件来管（判据见 spec 第一节：出了问题谁承担后果、谁有能力判断）。
///
/// 最要紧的一条：**锁必须能自愈**。持有者可能崩溃、被 kill、断电——没有
/// 自愈，任务会被一把永远不会释放的锁封死，用户完全无从下手。
void main() {
  late Directory dir;

  TaskLockFile lockFile() => TaskLockFile(dataDir: dir, taskId: 't1');

  setUp(() => dir = Directory.systemTemp.createTempSync('ishkafel_lock_'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('拿锁与放锁', () {
    test('没人持有时能拿到', () {
      expect(lockFile().acquire('agent'), isTrue);
      expect(lockFile().read()?.holder, 'agent');
    });

    test('别人持着时拿不到', () {
      lockFile().acquire('agent');
      expect(lockFile().acquire('gui'), isFalse);
    });

    test('同一个持有者重复获取算成功——重入不该失败', () {
      lockFile().acquire('agent');
      expect(lockFile().acquire('agent'), isTrue);
    });

    test('释放之后别人能拿', () {
      lockFile().acquire('agent');
      lockFile().release('agent');
      expect(lockFile().acquire('gui'), isTrue);
    });

    test('不是持有者，释放无效——不能替别人放锁', () {
      lockFile().acquire('agent');
      lockFile().release('gui');
      expect(lockFile().read()?.holder, 'agent');
    });
  });

  group('自愈', () {
    final t0 = DateTime.utc(2026, 8, 11, 12, 0, 0);

    test('心跳停了超过阈值就算失效', () {
      lockFile().acquire('agent', now: t0);
      final lock = lockFile().read()!;
      expect(lock.isStale(t0.add(const Duration(seconds: 30))), isFalse);
      expect(lock.isStale(t0.add(const Duration(seconds: 61))), isTrue);
    });

    test('失效之后别人能直接拿走——否则持有者一崩，任务就再也打不开', () {
      lockFile().acquire('agent', now: t0);
      expect(
        lockFile().acquire('gui', now: t0.add(const Duration(seconds: 61))),
        isTrue,
      );
      expect(lockFile().read()?.holder, 'gui');
    });

    test('心跳能续命', () {
      lockFile().acquire('agent', now: t0);
      lockFile()
          .heartbeat('agent', now: t0.add(const Duration(seconds: 50)));
      final lock = lockFile().read()!;
      expect(lock.isStale(t0.add(const Duration(seconds: 80))), isFalse,
          reason: '心跳之后重新计时');
    });

    test('不是持有者，心跳无效', () {
      lockFile().acquire('agent', now: t0);
      expect(lockFile().heartbeat('gui', now: t0), isFalse);
    });
  });

  group('强制接管', () {
    test('人要抢就能抢，抢完持有者换人', () {
      lockFile().acquire('agent');
      lockFile().forceTakeover('gui');
      expect(lockFile().read()?.holder, 'gui');
    });
  });

  group('坏掉的锁文件', () {
    test('读不懂就当作没锁——一个解析不了的锁不该把任务永久封死', () {
      Directory('${dir.path}/locks').createSync(recursive: true);
      File('${dir.path}/locks/t1.json').writeAsStringSync('{坏掉的');
      expect(lockFile().read(), isNull);
      expect(lockFile().acquire('gui'), isTrue);
    });

    test('字段缺失同理', () {
      Directory('${dir.path}/locks').createSync(recursive: true);
      File('${dir.path}/locks/t1.json').writeAsStringSync('{"holder":"x"}');
      expect(lockFile().read(), isNull);
    });
  });

  /// 真机上每次重启 app 打开任务都撞到：顶上一条黄横幅「这个任务被另一个
  /// 窗口占着，或者上一次没有正常退出（gui:82809），当前为只读」，
  /// 要么干等一分钟，要么点「强制接管」。
  ///
  /// 而那个 pid 的进程早就没了——写锁的那个 app 已经退出。进程都不在了还
  /// 让人等心跳超时，是白等。
  group('持有者的进程已经没了，锁立刻作废', () {
    TaskLock lockOf(String holder, DateTime beat) => TaskLock(
          holder: holder,
          acquiredAt: beat,
          heartbeatAt: beat,
        );

    final now = DateTime(2026, 8, 28, 12, 0, 0);

    test('进程不在了就算失效，不用等一分钟', () {
      final lock = lockOf('gui:82809', now.subtract(const Duration(seconds: 3)));

      expect(lock.isStale(now, processAlive: (pid) => false), isTrue);
    });

    test('进程还活着就照常等心跳——那可能真是另一个窗口开着', () {
      final lock = lockOf('gui:82809', now.subtract(const Duration(seconds: 3)));

      expect(lock.isStale(now, processAlive: (pid) => true), isFalse);
    });

    test('拿哪个 pid 去问，得跟持有者写的一致', () {
      final asked = <int>[];
      lockOf('agent:4242', now).isStale(now, processAlive: (pid) {
        asked.add(pid);
        return true;
      });

      expect(asked, [4242]);
    });

    test('持有者里没有 pid 就退回心跳判断，不瞎猜', () {
      final human = lockOf('人（审片台）', now.subtract(const Duration(seconds: 3)));

      expect(human.isStale(now, processAlive: (_) => false), isFalse);
    });

    test('心跳早就超时的，问都不用问', () {
      final old = lockOf('gui:82809', now.subtract(const Duration(minutes: 5)));

      expect(old.isStale(now, processAlive: (_) => true), isTrue);
    });
  });

}
