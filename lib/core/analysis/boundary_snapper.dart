/// 切点两级吸附（纯算法）：ASR 粗边界 → 窗口内吸附本地帧级信号
///
/// 优先级：镜头边界 > 静音谷 > 原位。最终结果一律帧对齐。
class BoundarySnapper {
  final int windowMs;

  const BoundarySnapper({this.windowMs = 600});

  /// 量化到最近的帧时刻
  int snapToFrame(int ms, double fps) {
    if (fps <= 0) return ms;
    final frame = (ms * fps / 1000).round();
    return (frame * 1000 / fps).round();
  }

  int? _nearestWithin(int ms, List<int> candidates) {
    int? best;
    var bestDist = windowMs + 1;
    for (final c in candidates) {
      final d = (c - ms).abs();
      if (d <= windowMs && d < bestDist) {
        best = c;
        bestDist = d;
      }
    }
    return best;
  }

  int snap(
    int roughMs, {
    required List<int> shotBoundaries,
    required List<int> silenceValleys,
    required double fps,
  }) {
    final shot = _nearestWithin(roughMs, shotBoundaries);
    if (shot != null) return snapToFrame(shot, fps);
    final valley = _nearestWithin(roughMs, silenceValleys);
    if (valley != null) return snapToFrame(valley, fps);
    return snapToFrame(roughMs, fps);
  }
}
