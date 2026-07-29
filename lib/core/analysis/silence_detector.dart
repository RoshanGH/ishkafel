import 'dart:math' as math;

/// 静音谷检测（纯算法）：窗口 RMS + 相对阈值 + 最短时长过滤
///
/// 阈值取全片窗口 RMS 中位数 × [thresholdRatio]——广告片语音区占主导，
/// 中位数即"说话音量"，其 15% 以下视为静音。
class SilenceDetector {
  final int windowMs;
  final double thresholdRatio;
  final int minSilenceMs;

  const SilenceDetector({
    this.windowMs = 20,
    this.thresholdRatio = 0.15,
    this.minSilenceMs = 200,
  });

  /// 返回每个静音谷的中心时刻（毫秒），升序
  List<int> detectValleyCenters(List<int> samples, int sampleRate) {
    if (samples.isEmpty) return const [];
    final perWindow = sampleRate * windowMs ~/ 1000;
    if (perWindow == 0) return const [];

    final rmsList = <double>[];
    for (var i = 0; i + perWindow <= samples.length; i += perWindow) {
      var sum = 0.0;
      for (var j = i; j < i + perWindow; j++) {
        sum += samples[j].toDouble() * samples[j].toDouble();
      }
      rmsList.add(math.sqrt(sum / perWindow));
    }
    if (rmsList.isEmpty) return const [];

    final sorted = [...rmsList]..sort();
    final threshold = sorted[sorted.length ~/ 2] * thresholdRatio;
    final minWindows = (minSilenceMs / windowMs).ceil();

    final centers = <int>[];
    var runStart = -1;
    for (var w = 0; w <= rmsList.length; w++) {
      final silent = w < rmsList.length && rmsList[w] <= threshold;
      if (silent && runStart < 0) runStart = w;
      if (!silent && runStart >= 0) {
        if (w - runStart >= minWindows) {
          centers.add(((runStart + w) * windowMs / 2).round());
        }
        runStart = -1;
      }
    }
    return centers;
  }
}
