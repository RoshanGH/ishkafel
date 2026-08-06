/// 落在同一个价格档里的用量小计
class TierUsage {
  final int calls;

  /// **未命中缓存**的输入 token（按输入价计费）
  final int promptTokens;

  /// 命中缓存的输入 token（按缓存价计费，只有输入价的五分之一）
  final int cachedTokens;
  final int completionTokens;

  const TierUsage({
    this.calls = 0,
    this.promptTokens = 0,
    this.cachedTokens = 0,
    this.completionTokens = 0,
  });

  TierUsage plus(
          {required int prompt, required int cached, required int completion}) =>
      TierUsage(
        calls: calls + 1,
        promptTokens: promptTokens + prompt,
        cachedTokens: cachedTokens + cached,
        completionTokens: completionTokens + completion,
      );

  TierUsage merge(TierUsage other) => TierUsage(
        calls: calls + other.calls,
        promptTokens: promptTokens + other.promptTokens,
        cachedTokens: cachedTokens + other.cachedTokens,
        completionTokens: completionTokens + other.completionTokens,
      );

  Map<String, dynamic> toJson() => {
        'calls': calls,
        'promptTokens': promptTokens,
        'cachedTokens': cachedTokens,
        'completionTokens': completionTokens,
      };

  static TierUsage? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    return TierUsage(
      calls: _int(raw['calls']),
      promptTokens: _int(raw['promptTokens']),
      cachedTokens: _int(raw['cachedTokens']),
      completionTokens: _int(raw['completionTokens']),
    );
  }

  static int _int(Object? v) => v is num ? v.toInt() : 0;
}

/// 一个模型的用量小计，**按价格档分开存**。
///
/// 方舟是分段计费：单价看的是**每一次请求**的输入长度（≤32K / 32–128K /
/// 128–256K），跨一档单价翻倍。先把所有请求的 token 加总再定档会算错——
/// 一百次小请求加起来超过 32K，并不等于它们该按第二档收费。
class ModelUsage {
  final Map<int, TierUsage> byTier;

  const ModelUsage([this.byTier = const {}]);

  int get calls => byTier.values.fold(0, (n, u) => n + u.calls);

  /// 展示用的输入总量（含命中缓存的部分）——用户要拿它跟账单对
  int get promptTokens =>
      byTier.values.fold(0, (n, u) => n + u.promptTokens + u.cachedTokens);
  int get cachedTokens =>
      byTier.values.fold(0, (n, u) => n + u.cachedTokens);
  int get completionTokens =>
      byTier.values.fold(0, (n, u) => n + u.completionTokens);

  ModelUsage plusAt(
          {required int tier,
          required int prompt,
          required int cached,
          required int completion}) =>
      ModelUsage(Map.unmodifiable({
        ...byTier,
        tier: (byTier[tier] ?? const TierUsage())
            .plus(prompt: prompt, cached: cached, completion: completion),
      }));

  ModelUsage merge(ModelUsage other) {
    final merged = <int, TierUsage>{...byTier};
    for (final entry in other.byTier.entries) {
      merged[entry.key] =
          (merged[entry.key] ?? const TierUsage()).merge(entry.value);
    }
    return ModelUsage(Map.unmodifiable(merged));
  }

  Map<String, dynamic> toJson() => {
        'byTier': {
          for (final entry in byTier.entries) '${entry.key}': entry.value.toJson(),
        },
      };

  /// 兼容旧存档：没有 `byTier` 的一律当作第一档——那时所有真实请求都在
  /// 3000 token 上下，落档是对的
  static ModelUsage? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final byTier = raw['byTier'];
    if (byTier is Map) {
      final parsed = <int, TierUsage>{};
      for (final entry in byTier.entries) {
        final tier = int.tryParse('${entry.key}');
        final value = TierUsage.tryFromJson(entry.value);
        if (tier == null || value == null) continue;
        parsed[tier] = value;
      }
      return ModelUsage(Map.unmodifiable(parsed));
    }
    final legacy = TierUsage.tryFromJson(raw);
    return legacy == null ? null : ModelUsage(Map.unmodifiable({0: legacy}));
  }
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

/// 一个价格档：输入长度上限（token）与该档的三个单价（元/百万 token）
typedef ArkTier = ({int maxPromptTokens, double input, double cached, double output});

/// 火山方舟「在线推理（常规）」单价。
///
/// 来源：官方《模型服务价格》文档（82379/1544106）。
///
/// **分段计费**：单价看的是**每次请求**的输入长度，不是累计量。官方举例：
/// 「请求输入 200k tokens…满足 输入长度 (128, 256] 条件，输入输出 token
/// 按该档单价计费」——注意输出也跟着输入长度走档。
///
/// 按**前缀**匹配模型名：同一系列换日期后缀单价不变，逐个全名列价的话，
/// 模型一升级花费就变成「算不出来」。
abstract final class ArkPricing {
  static const Map<String, List<ArkTier>> _tiers = {
    'doubao-seed-2-0-mini': [
      (maxPromptTokens: 32000, input: 0.2, cached: 0.04, output: 2.0),
      (maxPromptTokens: 128000, input: 0.4, cached: 0.08, output: 4.0),
      (maxPromptTokens: 256000, input: 0.8, cached: 0.16, output: 8.0),
    ],
    'doubao-seed-2-0-lite': [
      (maxPromptTokens: 32000, input: 0.6, cached: 0.12, output: 3.6),
      (maxPromptTokens: 128000, input: 0.9, cached: 0.18, output: 5.4),
      (maxPromptTokens: 256000, input: 1.8, cached: 0.36, output: 10.8),
    ],
    'doubao-seed-2-0-pro': [
      (maxPromptTokens: 32000, input: 3.2, cached: 0.64, output: 16.0),
      (maxPromptTokens: 128000, input: 4.8, cached: 0.96, output: 24.0),
      (maxPromptTokens: 256000, input: 9.6, cached: 1.92, output: 48.0),
    ],
  };

  static List<ArkTier>? _tiersFor(String model) {
    for (final entry in _tiers.entries) {
      if (model.startsWith(entry.key)) return entry.value;
    }
    return null;
  }

  /// 这次请求落在第几档；不认识的模型返回 null。
  ///
  /// 超过最高档时**按最高档算**而不是返回 null：越界会让整份花费变成
  /// 「未知」，而火山那边是照扣钱的。
  static int? tierOf({required String model, required int promptTokens}) {
    final tiers = _tiersFor(model);
    if (tiers == null) return null;
    for (var i = 0; i < tiers.length; i++) {
      if (promptTokens <= tiers[i].maxPromptTokens) return i;
    }
    return tiers.length - 1;
  }

  /// 某一档里这些 token 花了多少钱；不认识的模型返回 null。
  ///
  /// **不认识就说不知道，不按 0 算**：悄悄按 0 会让用户以为这次没花钱，
  /// 而实际账单照扣。
  static double? costOf({
    required String model,
    required int tier,
    required int prompt,
    required int cached,
    required int completion,
  }) {
    final tiers = _tiersFor(model);
    if (tiers == null) return null;
    final t = tiers[tier.clamp(0, tiers.length - 1)];
    return prompt / 1000000 * t.input +
        cached / 1000000 * t.cached +
        completion / 1000000 * t.output;
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
  int get cachedTokens =>
      byModel.values.fold(0, (n, u) => n + u.cachedTokens);
  int get completionTokens =>
      byModel.values.fold(0, (n, u) => n + u.completionTokens);
  int get totalTokens => promptTokens + completionTokens;

  /// 用不出价的模型；界面据此说明「花费算不全」
  List<String> get unpricedModels => [
        for (final model in byModel.keys)
          if (ArkPricing.tierOf(model: model, promptTokens: 0) == null) model,
      ];

  /// 累计花费（元）。有任何一个模型不认识就返回 null——给一个偏低的数字
  /// 比说「不知道」更糟。
  double? get costYuan {
    var total = 0.0;
    for (final entry in byModel.entries) {
      final cost = costOfModel(entry.key);
      if (cost == null) return null;
      total += cost;
    }
    for (final entry in byService.entries) {
      total += SpeechPricing.costOf(entry.key, entry.value.quantity);
    }
    return total;
  }

  /// 单个模型累计花了多少；不认识的返回 null
  double? costOfModel(String model) {
    final usage = byModel[model];
    if (usage == null) return null;
    var total = 0.0;
    for (final entry in usage.byTier.entries) {
      final cost = ArkPricing.costOf(
          model: model,
          tier: entry.key,
          prompt: entry.value.promptTokens,
          cached: entry.value.cachedTokens,
          completion: entry.value.completionTokens);
      if (cost == null) return null;
      total += cost;
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

  /// 记一次调用。
  ///
  /// [promptTokens] 是这次请求的**输入总量**（含命中缓存的部分），档位就按
  /// 它定；[cachedTokens] 是其中命中缓存的部分，会从按输入价计费的量里扣掉
  /// ——官方口径是「未被命中的 token 仍按 prompt_token 计费」。
  AiUsage plus({
    required String model,
    required int promptTokens,
    int cachedTokens = 0,
    required int completionTokens,
  }) {
    final tier = ArkPricing.tierOf(model: model, promptTokens: promptTokens) ?? 0;
    final billableCached = cachedTokens.clamp(0, promptTokens);
    return AiUsage(
        Map.unmodifiable({
          ...byModel,
          model: (byModel[model] ?? const ModelUsage()).plusAt(
              tier: tier,
              prompt: promptTokens - billableCached,
              cached: billableCached,
              completion: completionTokens),
        }),
        byService);
  }

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
