import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/playback_gate.dart';

void main() {
  group('销毁要等在跑的播放器命令收尾', () {
    test('还有命令没跑完时，销毁先等着', () async {
      final gate = PlaybackGate();
      final loading = Completer<void>();
      var tornDown = false;

      unawaited(gate.run(() => loading.future));
      unawaited(gate.close(() async => tornDown = true));
      await Future<void>.delayed(Duration.zero);

      expect(tornDown, isFalse,
          reason: '一次 open 还在路上就把 mpv 销毁掉，进程会直接 abort——'
              '用户看到的是「返回后再点一个任务就闪退」');

      loading.complete();
      await Future<void>.delayed(Duration.zero);
      expect(tornDown, isTrue);
    });

    test('没有命令在跑时立刻销毁', () async {
      final gate = PlaybackGate();
      var tornDown = false;

      await gate.close(() async => tornDown = true);

      expect(tornDown, isTrue);
    });

    test('命令抛错也照样放行销毁——否则一次失败的打开就把播放器永远泄漏在那',
        () async {
      final gate = PlaybackGate();
      var tornDown = false;

      // 错误照常抛给调用方（这里吞掉只是为了不让它变成未处理异常）
      unawaited(gate
          .run(() async => throw Exception('文件不存在'))
          .catchError((Object _) => null));
      await gate.close(() async => tornDown = true);

      expect(tornDown, isTrue);
    });

    test('等超时了也要销毁：卡死一个播放器好过整个进程挂在那', () async {
      final gate = PlaybackGate();
      var tornDown = false;

      unawaited(gate.run(() => Completer<void>().future)); // 永远不完成
      await gate.close(() async => tornDown = true,
          timeout: const Duration(milliseconds: 10));

      expect(tornDown, isTrue);
    });

    test('销毁之后来的命令直接丢弃，不去碰已经没了的播放器', () async {
      final gate = PlaybackGate();
      var ran = false;

      await gate.close(() async {});
      final result = await gate.run(() async {
        ran = true;
        return 1;
      });

      expect(ran, isFalse);
      expect(result, isNull, reason: '调用方据此降级，而不是拿到一个假成功');
    });

    test('重复销毁只执行一次', () async {
      final gate = PlaybackGate();
      var count = 0;

      await gate.close(() async => count++);
      await gate.close(() async => count++);

      expect(count, 1);
    });

    test('并发命令都跑完才销毁', () async {
      final gate = PlaybackGate();
      final a = Completer<void>();
      final b = Completer<void>();
      var tornDown = false;

      unawaited(gate.run(() => a.future));
      unawaited(gate.run(() => b.future));
      unawaited(gate.close(() async => tornDown = true));

      a.complete();
      await Future<void>.delayed(Duration.zero);
      expect(tornDown, isFalse, reason: '还有一条没回来');

      b.complete();
      await Future<void>.delayed(Duration.zero);
      expect(tornDown, isTrue);
    });

    test('命令原样返回结果，不改变正常路径的行为', () async {
      final gate = PlaybackGate();

      expect(await gate.run(() async => 42), 42);
    });
  });
}
