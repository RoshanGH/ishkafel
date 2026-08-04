/// 把合成语音的时长对齐到原声。
///
/// 换音色最容易露馅的地方不是音色本身，是**节奏对不上**——同一句话不同音色
/// 的自然时长能差两成（实测「再不买就恢复69.9一瓶了」原声 2520ms，通用女声
/// 念出来 3072ms），画面还是原来的画面，一放就飘。
///
/// 两级对齐：
/// 1. 合成时用接口的 `speech_rate` 粗调——这是模型自己重新组织语速，
///    比事后拉伸自然得多；
/// 2. 剩下的误差用 ffmpeg 的 `atempo` 精调，它只改速度不改音高。
abstract final class SpeechAlignment {
  /// 接口允许的语速范围（实测：50 → 2016ms，-30 → 4368ms，基线 ~2970ms）
  static const int minRate = -50;
  static const int maxRate = 100;

  /// 差在这个比例以内就不调语速。为几十毫秒改语速，反而会让这一句听起来
  /// 和前后不是一个人在说。
  static const double rateTolerance = 0.04;

  /// 差在这个比例以内就不挂变速滤镜——为十几毫秒做一次重采样，
  /// 白白引入音质损失。
  static const double tempoTolerance = 0.02;

  /// 该给接口传什么 `speech_rate`。0 表示不用调。
  ///
  /// 正数加速、负数减速。这里用线性近似：实测 rate=50 把时长压到 0.68 倍、
  /// rate=-30 拉到 1.45 倍，在我们关心的 ±30% 区间内足够准，剩下的交给
  /// 第二级。
  static int rateFor({required int synthesizedMs, required int targetMs}) {
    if (synthesizedMs <= 0 || targetMs <= 0) return 0;
    final ratio = synthesizedMs / targetMs;
    if ((ratio - 1).abs() <= rateTolerance) return 0;
    // ratio > 1 表示合成偏慢，要加速（正 rate）
    final rate = ((ratio - 1) * 100).round();
    return rate.clamp(minRate, maxRate);
  }

  /// 第二级：还差多少倍。1.0 表示不用变速。
  static double tempoFor({required int actualMs, required int targetMs}) {
    if (actualMs <= 0 || targetMs <= 0) return 1;
    final ratio = actualMs / targetMs;
    return (ratio - 1).abs() <= tempoTolerance ? 1 : ratio;
  }

  /// `atempo` 单次只支持 0.5~2.0，超出要拆成多级串联。
  ///
  /// 非法倍率（0、负数）返回空链——生成一个会让 ffmpeg 直接报错的滤镜，
  /// 等于把一次可恢复的「不变速」变成整条命令失败。
  static List<double> tempoChain(double tempo) {
    if (tempo <= 0 || tempo == 1) return const [];
    final chain = <double>[];
    var remaining = tempo;
    while (remaining > 2.0) {
      chain.add(2.0);
      remaining /= 2.0;
    }
    while (remaining < 0.5) {
      chain.add(0.5);
      remaining /= 0.5;
    }
    chain.add(remaining);
    return List.unmodifiable(chain);
  }

  /// 拼成 ffmpeg 的滤镜表达式；不需要变速时返回 null，
  /// 调用方据此整段跳过 `-filter:a`
  static String? atempoFilter(double tempo) {
    final chain = tempoChain(tempo);
    if (chain.isEmpty) return null;
    return chain.map((t) => 'atempo=${t.toStringAsFixed(6)}').join(',');
  }

  /// 便利：算出「合成完之后还要不要变速」
  static String? filterFor({required int actualMs, required int targetMs}) =>
      atempoFilter(tempoFor(actualMs: actualMs, targetMs: targetMs));

  /// 供上层展示：对齐后与目标差多少毫秒（用于「对不齐时如实告诉用户」）
  static int residualMs({required int actualMs, required int targetMs}) =>
      (actualMs - targetMs).abs();

  /// 夹住极端值，避免把一句话压成听不清的快板
  static double clampTempo(double tempo) => tempo.clamp(0.5, 2.0);
}
