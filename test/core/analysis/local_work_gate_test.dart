import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/local_work_gate.dart';

void main() {
  test('同时在跑的活不超过放行数', () async {
    final gate = LocalWorkGate(permits: 2);
    final release = Completer<void>();
    var running = 0;
    var peak = 0;

    final jobs = [
      for (var i = 0; i < 5; i++)
        gate.run(() async {
          running++;
          peak = peak > running ? peak : running;
          await release.future;
          running--;
        }),
    ];
    await Future<void>.delayed(Duration.zero);

    expect(peak, 2, reason: '58 个镜头各抽 3 帧，一次性放出 174 个 ffmpeg '
        '抢 8 个核，只会互相拖慢');

    release.complete();
    await Future.wait(jobs);
    expect(running, 0);
  });

  test('抛错也要放行，不然一次失败就把闸卡死', () async {
    final gate = LocalWorkGate(permits: 1);

    await expectLater(
        gate.run(() async => throw Exception('抽帧失败')), throwsException);
    // 闸没被占死：下一个活照常能跑
    expect(await gate.run(() async => 42), 42);
  });

  test('放行数默认取核心数', () {
    expect(LocalWorkGate().permits, greaterThan(0));
  });
}
