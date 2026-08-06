import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_usage_scope.dart';

void main() {
  test('记在当前这一笔账上', () async {
    final usage = await AiUsageScope.collect(() async {
      AiUsageScope.record(model: 'mini', prompt: 10, completion: 2);
      AiUsageScope.record(model: 'mini', prompt: 5, completion: 1);
    });

    expect(usage.calls, 2);
    expect(usage.promptTokens, 15);
  });

  test('嵌在深处的异步调用也记得到——打标是层层 await 下去的', () async {
    final usage = await AiUsageScope.collect(() async {
      await Future<void>.delayed(Duration.zero);
      await Future.wait([
        for (var i = 0; i < 3; i++)
          () async {
            await Future<void>.delayed(Duration.zero);
            AiUsageScope.record(model: 'mini', prompt: 1, completion: 1);
          }(),
      ]);
    });

    expect(usage.calls, 3);
  });

  test('两个任务同时分析时各记各的，不串账', () async {
    late Completer<void> gate;
    gate = Completer<void>();

    final a = AiUsageScope.collect(() async {
      AiUsageScope.record(model: 'mini', prompt: 100, completion: 0);
      await gate.future;
      AiUsageScope.record(model: 'mini', prompt: 100, completion: 0);
    });
    final b = AiUsageScope.collect(() async {
      AiUsageScope.record(model: 'lite', prompt: 7, completion: 0);
    });

    gate.complete();
    final usageA = await a;
    final usageB = await b;

    expect(usageA.promptTokens, 200);
    expect(usageA.byModel.containsKey('lite'), isFalse,
        reason: '串账的话用户会看到别的任务的花费记在自己头上');
    expect(usageB.promptTokens, 7);
  });

  test('不在记账范围里调用也不炸——重打标之外还有别处会用到同一个客户端', () {
    expect(() => AiUsageScope.record(model: 'mini', prompt: 1, completion: 1),
        returnsNormally);
  });

  test('body 抛异常时账照样交出来——花了的钱不因为失败就不算', () async {
    var recorded = 0;
    try {
      await AiUsageScope.collect(() async {
        AiUsageScope.record(model: 'mini', prompt: 10, completion: 0);
        throw Exception('打标失败');
      }, onPartial: (u) => recorded = u.promptTokens);
      fail('异常应该往外抛');
    } catch (_) {
      expect(recorded, 10);
    }
  });
}
