import 'dart:async';

import 'ai_usage.dart';

/// 「这笔调用算在哪个任务头上」的记账范围。
///
/// 用 Zone 而不是把收集器一层层传下去：一次分析里的 Ark 调用埋在
/// 管线 → 打标服务 → 各个 tagger 底下，且几十个并发同时在跑。逐层加参数会
/// 污染每一个中间接口，而全局静态计数在两个任务同时分析时会直接串账。
/// Zone 正是为这种「环境上下文」准备的：范围内的所有异步调用自动继承。
abstract final class AiUsageScope {
  static const _key = #ishkafelAiUsage;

  /// 在一笔账里跑 [body]，返回期间累计的用量。
  ///
  /// [body] 抛异常时用量通过 [onPartial] 交出去再把异常往外抛——花掉的
  /// token 不会因为这次失败就退回来，账要照记。
  static Future<AiUsage> collect(
    Future<void> Function() body, {
    void Function(AiUsage partial)? onPartial,
  }) async {
    final collector = _Collector();
    try {
      await runZoned(body, zoneValues: {_key: collector});
    } catch (_) {
      onPartial?.call(collector.usage);
      rethrow;
    }
    return collector.usage;
  }

  /// 记一笔按时长/字符计费的语音调用。[quantity] 的单位见
  /// [SpeechService.unit]
  static void recordService({
    required SpeechService service,
    required int quantity,
  }) {
    final collector = Zone.current[_key];
    if (collector is! _Collector) return;
    collector.addService(service, quantity);
  }

  /// 记一笔。不在任何记账范围里时静默忽略——同一个 Ark 客户端在别处
  /// （比如启动期探测）也会被用到，那些调用没有归属，不该让它抛错。
  static void record({
    required String model,
    required int prompt,
    required int completion,
  }) {
    final collector = Zone.current[_key];
    if (collector is! _Collector) return;
    collector.add(model: model, prompt: prompt, completion: completion);
  }
}

class _Collector {
  AiUsage usage = AiUsage.empty;

  void add({
    required String model,
    required int prompt,
    required int completion,
  }) {
    usage = usage.plus(
        model: model, promptTokens: prompt, completionTokens: completion);
  }

  void addService(SpeechService service, int quantity) {
    usage = usage.plusService(service: service, quantity: quantity);
  }
}
