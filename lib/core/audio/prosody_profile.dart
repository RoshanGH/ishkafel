import '../analysis/providers.dart';

/// 相对全片均值的快慢
enum Pace {
  slow('偏慢'),
  normal('正常'),
  fast('偏快');

  final String label;
  const Pace(this.label);
}

/// 一段原声「是怎么念的」的可量化画像。
///
/// 为什么是测量而不是让模型听：本账号下方舟的 60 个可用模型没有一个支持音频
/// 输入，录音文件识别（1.0/2.0）也不返回任何情感字段——实测过。而语速、停顿、
/// 强调这几样恰恰是带货口播里「那股劲」的主体，它们从字级时间戳就能算出来，
/// 确定性强、成本为零、还能向用户解释依据。
///
/// 抓不住的部分（音色的微妙口气、语调曲线）如实承认：见 [hasSignal] 与
/// 各字段的文档。将来有能听音频的模型，换掉产出这个画像的那一层即可。
class ProsodyProfile {
  /// 每秒几个字（按有效说话时长算，不含前后静音）
  final double charsPerSec;

  /// 相对全片均值的快慢
  final Pace pace;

  /// 字间空档超过 [pauseThresholdMs] 的次数
  final int pauseCount;
  final int longestPauseMs;

  /// 被明显拖长的字——重音的代理信号。「69.9」占了 800ms、是平均字长的三倍，
  /// 说明价格被刻意强调。
  final List<String> stressedWords;

  /// 有没有量到东西。没有字级时间戳时为 false——量不出来就要说出来，
  /// 别让上层把一个空画像当成「这段话平平淡淡」。
  final bool hasSignal;

  const ProsodyProfile({
    required this.charsPerSec,
    required this.pace,
    required this.pauseCount,
    required this.longestPauseMs,
    required this.stressedWords,
    required this.hasSignal,
  });

  /// 字间空档超过多少算一次停顿。100ms 以下是连读时的自然衔接，算进去
  /// 会让每句话都显得「停顿很多」。
  static const int pauseThresholdMs = 100;

  /// 字长超过平均的多少倍算被拖长
  static const double stressRatio = 2.0;

  /// 与全片均值差多少才算快/慢。15% 以内是正常波动，硬分快慢只会让
  /// 生成的指令自相矛盾。
  static const double paceTolerance = 0.15;

  static ProsodyProfile measure({
    required List<AsrWord> words,
    required double referenceCharsPerSec,
  }) {
    final valid = [
      for (final w in words)
        if (w.endMs > w.startMs) w,
    ];
    if (valid.isEmpty) {
      return const ProsodyProfile(
        charsPerSec: 0,
        pace: Pace.normal,
        pauseCount: 0,
        longestPauseMs: 0,
        stressedWords: [],
        hasSignal: false,
      );
    }

    final spanMs = valid.last.endMs - valid.first.startMs;
    final charsPerSec = spanMs > 0 ? valid.length * 1000 / spanMs : 0.0;

    var pauseCount = 0;
    var longestPause = 0;
    for (var i = 1; i < valid.length; i++) {
      final gap = valid[i].startMs - valid[i - 1].endMs;
      if (gap < pauseThresholdMs) continue;
      pauseCount++;
      if (gap > longestPause) longestPause = gap;
    }

    final durations = [for (final w in valid) w.endMs - w.startMs];
    final avg = durations.reduce((a, b) => a + b) / durations.length;
    final stressed = [
      for (var i = 0; i < valid.length; i++)
        if (durations[i] >= avg * stressRatio) valid[i].text,
    ];

    return ProsodyProfile(
      charsPerSec: charsPerSec,
      pace: _paceOf(charsPerSec, referenceCharsPerSec),
      pauseCount: pauseCount,
      longestPauseMs: longestPause,
      stressedWords: List.unmodifiable(stressed),
      hasSignal: true,
    );
  }

  static Pace _paceOf(double actual, double reference) {
    if (reference <= 0 || actual <= 0) return Pace.normal;
    final ratio = actual / reference;
    if (ratio > 1 + paceTolerance) return Pace.fast;
    if (ratio < 1 - paceTolerance) return Pace.slow;
    return Pace.normal;
  }

  /// 摊成一句给模型看的事实陈述。
  ///
  /// 只陈述测到的事实，不替模型下「所以这是着急的语气」这种结论——那一步
  /// 交给模型，它才知道结合台词该怎么说。
  String describe() {
    if (!hasSignal) return '（没有可用的语速与停顿数据）';
    final parts = <String>[
      '语速 ${charsPerSec.toStringAsFixed(1)} 字/秒（相对全片${pace.label}）',
      pauseCount == 0
          ? '中间没有明显停顿，一气呵成'
          : '中间有 $pauseCount 处停顿，最长 ${longestPauseMs}ms',
      if (stressedWords.isNotEmpty) '「${stressedWords.join('」「')}」被明显拖长',
    ];
    return parts.join('；');
  }
}
