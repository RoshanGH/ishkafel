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

/// 按时长 / 字符计费的语音服务。
///
/// 与方舟的 token 计费是两套单位，不能混在一张表里算——那样只会把「小时」
/// 当成「百万 token」乘。
enum SpeechService {
  /// 大模型录音文件识别（极速版），resource id `volc.bigasr.auc_turbo`。
  /// 按音频**秒数**累计，4.5 元/小时
  asrFlash(unit: '秒', label: '语音识别（极速版）'),

  /// 豆包语音合成模型 2.0，resource id `seed-tts-2.0`。
  /// 按**字符数**累计（一个汉字算一个字符），3 元/万字符
  tts(unit: '字符', label: '语音合成'),

  /// 豆包声音复刻模型 2.0，resource id `seed-icl-2.0`。同为 3 元/万字符，
  /// 但分开记账——用户要看得出钱花在预置音色还是复刻音色上
  voiceClone(unit: '字符', label: '声音复刻');

  final String unit;
  final String label;
  const SpeechService({required this.unit, required this.label});

  static SpeechService? byName(String name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// 一个语音服务的用量小计。[quantity] 的单位见 [SpeechService.unit]
class ServiceUsage {
  final int calls;
  final int quantity;

  const ServiceUsage({this.calls = 0, this.quantity = 0});

  ServiceUsage plus(int amount) =>
      ServiceUsage(calls: calls + 1, quantity: quantity + amount);

  ServiceUsage merge(ServiceUsage other) => ServiceUsage(
      calls: calls + other.calls, quantity: quantity + other.quantity);

  Map<String, dynamic> toJson() => {'calls': calls, 'quantity': quantity};

  static ServiceUsage? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    return ServiceUsage(
      calls: raw['calls'] is num ? (raw['calls'] as num).toInt() : 0,
      quantity: raw['quantity'] is num ? (raw['quantity'] as num).toInt() : 0,
    );
  }
}

/// 语音服务的单价（后付费目录价）。来源：火山「豆包语音-计费说明」。
abstract final class SpeechPricing {
  /// 元/小时
  static const double asrPerHour = 4.5;

  /// 元/万字符
  static const double ttsPer10kChars = 3.0;

  static double costOf(SpeechService service, int quantity) =>
      switch (service) {
        SpeechService.asrFlash => quantity / 3600 * asrPerHour,
        SpeechService.tts ||
        SpeechService.voiceClone =>
          quantity / 10000 * ttsPer10kChars,
      };
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

  /// 按时长/字符计费的语音服务
  final Map<SpeechService, ServiceUsage> byService;

  const AiUsage(this.byModel, [this.byService = const {}]);

  static const AiUsage empty = AiUsage({});

  int get calls =>
      byModel.values.fold(0, (n, u) => n + u.calls) +
      byService.values.fold(0, (n, u) => n + u.calls);
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
    for (final entry in byService.entries) {
      total += SpeechPricing.costOf(entry.key, entry.value.quantity);
    }
    return total;
  }

  AiUsage plusService(
          {required SpeechService service, required int quantity}) =>
      AiUsage(
          byModel,
          Map.unmodifiable({
            ...byService,
            service: (byService[service] ?? const ServiceUsage()).plus(quantity),
          }));

  AiUsage plus({
    required String model,
    required int promptTokens,
    required int completionTokens,
  }) =>
      AiUsage(
          Map.unmodifiable({
            ...byModel,
            model: (byModel[model] ?? const ModelUsage())
                .plus(prompt: promptTokens, completion: completionTokens),
          }),
          byService);

  AiUsage merge(AiUsage other) {
    final merged = <String, ModelUsage>{...byModel};
    for (final entry in other.byModel.entries) {
      merged[entry.key] =
          (merged[entry.key] ?? const ModelUsage()).merge(entry.value);
    }
    final mergedServices = <SpeechService, ServiceUsage>{...byService};
    for (final entry in other.byService.entries) {
      mergedServices[entry.key] =
          (mergedServices[entry.key] ?? const ServiceUsage())
              .merge(entry.value);
    }
    return AiUsage(
        Map.unmodifiable(merged), Map.unmodifiable(mergedServices));
  }

  Map<String, dynamic> toJson() => {
        'byModel': {
          for (final entry in byModel.entries) entry.key: entry.value.toJson(),
        },
        'byService': {
          for (final entry in byService.entries)
            entry.key.name: entry.value.toJson(),
        },
      };

  /// 宽松解析：老任务没有这个字段就是「没花过」，坏条目跳过不牵连其余
  static AiUsage fromJson(Object? raw) {
    if (raw is! Map) return empty;
    final parsed = <String, ModelUsage>{};
    final byModel = raw['byModel'];
    if (byModel is Map) {
      for (final entry in byModel.entries) {
        final key = entry.key;
        final value = ModelUsage.tryFromJson(entry.value);
        if (key is! String || value == null) continue;
        parsed[key] = value;
      }
    }
    final services = <SpeechService, ServiceUsage>{};
    final byService = raw['byService'];
    if (byService is Map) {
      for (final entry in byService.entries) {
        // 不认识的服务名跳过：可能是更新版本写的，按 0 算总比算错强
        final key = entry.key is String
            ? SpeechService.byName(entry.key as String)
            : null;
        final value = ServiceUsage.tryFromJson(entry.value);
        if (key == null || value == null) continue;
        services[key] = value;
      }
    }
    return AiUsage(Map.unmodifiable(parsed), Map.unmodifiable(services));
  }
}
