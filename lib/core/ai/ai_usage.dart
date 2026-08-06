/// 一个模型的用量小计
class ModelUsage {
  final int calls;
  final int promptTokens;
  final int completionTokens;

  const ModelUsage({
    this.calls = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  ModelUsage plus({required int prompt, required int completion}) => ModelUsage(
        calls: calls + 1,
        promptTokens: promptTokens + prompt,
        completionTokens: completionTokens + completion,
      );

  ModelUsage merge(ModelUsage other) => ModelUsage(
        calls: calls + other.calls,
        promptTokens: promptTokens + other.promptTokens,
        completionTokens: completionTokens + other.completionTokens,
      );

  Map<String, dynamic> toJson() => {
        'calls': calls,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
      };

  static ModelUsage? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    return ModelUsage(
      calls: _int(raw['calls']),
      promptTokens: _int(raw['promptTokens']),
      completionTokens: _int(raw['completionTokens']),
    );
  }

  static int _int(Object? v) => v is num ? v.toInt() : 0;
}

/// 火山方舟的单价（元 / 百万 token，≤32K 上下文档）。
///
/// **来源存疑**：官方定价页是前端渲染的，抓不到正文；这里的数字取自公开的
/// 二手汇总。真实账单以火山控制台为准——发现对不上就改这一张表，全局生效。
///
/// 按**前缀**匹配而不是全名：同一系列换个日期后缀（`-260215` → `-260428`）
/// 单价不变，逐个全名列价的话，模型一升级花费就变成「算不出来」。
abstract final class ArkPricing {
  static const Map<String, ({double input, double output})> _perMillion = {
    'doubao-seed-2-0-mini': (input: 0.2, output: 2.0),
    'doubao-seed-2-0-lite': (input: 0.6, output: 3.6),
    'doubao-seed-2-0-pro': (input: 2.4, output: 24.0),
  };

  /// 这次调用花了多少钱；不认识的模型返回 null。
  ///
  /// **不认识就说不知道，不按 0 算**：悄悄按 0 会让用户以为这次没花钱，
  /// 而实际账单照扣。
  static double? costOf(
      {required String model, required int prompt, required int completion}) {
    for (final entry in _perMillion.entries) {
      if (model.startsWith(entry.key)) {
        return prompt / 1000000 * entry.value.input +
            completion / 1000000 * entry.value.output;
      }
    }
    return null;
  }
}

/// 一个任务累计花掉的 AI 用量。
///
/// **不可变**：就地累加会让「这次分析花了多少」永远算不准——上一次的余额还在
/// 同一个对象里。
class AiUsage {
  final Map<String, ModelUsage> byModel;

  const AiUsage(this.byModel);

  static const AiUsage empty = AiUsage({});

  int get calls => byModel.values.fold(0, (n, u) => n + u.calls);
  int get promptTokens =>
      byModel.values.fold(0, (n, u) => n + u.promptTokens);
  int get completionTokens =>
      byModel.values.fold(0, (n, u) => n + u.completionTokens);
  int get totalTokens => promptTokens + completionTokens;

  /// 用不出价的模型；界面据此说明「花费算不全」
  List<String> get unpricedModels => [
        for (final model in byModel.keys)
          if (ArkPricing.costOf(model: model, prompt: 0, completion: 0) == null)
            model,
      ];

  /// 累计花费（元）。有任何一个模型不认识就返回 null——给一个偏低的数字
  /// 比说「不知道」更糟。
  double? get costYuan {
    var total = 0.0;
    for (final entry in byModel.entries) {
      final cost = ArkPricing.costOf(
          model: entry.key,
          prompt: entry.value.promptTokens,
          completion: entry.value.completionTokens);
      if (cost == null) return null;
      total += cost;
    }
    return total;
  }

  AiUsage plus({
    required String model,
    required int promptTokens,
    required int completionTokens,
  }) =>
      AiUsage(Map.unmodifiable({
        ...byModel,
        model: (byModel[model] ?? const ModelUsage())
            .plus(prompt: promptTokens, completion: completionTokens),
      }));

  AiUsage merge(AiUsage other) {
    final merged = <String, ModelUsage>{...byModel};
    for (final entry in other.byModel.entries) {
      merged[entry.key] =
          (merged[entry.key] ?? const ModelUsage()).merge(entry.value);
    }
    return AiUsage(Map.unmodifiable(merged));
  }

  Map<String, dynamic> toJson() => {
        'byModel': {
          for (final entry in byModel.entries) entry.key: entry.value.toJson(),
        },
      };

  /// 宽松解析：老任务没有这个字段就是「没花过」，坏条目跳过不牵连其余
  static AiUsage fromJson(Object? raw) {
    if (raw is! Map) return empty;
    final byModel = raw['byModel'];
    if (byModel is! Map) return empty;
    final parsed = <String, ModelUsage>{};
    for (final entry in byModel.entries) {
      final key = entry.key;
      final value = ModelUsage.tryFromJson(entry.value);
      if (key is! String || value == null) continue;
      parsed[key] = value;
    }
    return AiUsage(Map.unmodifiable(parsed));
  }
}
