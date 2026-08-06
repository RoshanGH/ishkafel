/// 把「全片要抽的这一堆帧」排成一次 ffmpeg 能跑完的形状。
///
/// 现状是每帧一次 ffmpeg：`-ss` 放在 `-i` 前面走关键帧快速定位，单帧很便宜，
/// 但 153 帧就是 153 次进程启动 + 153 次定位。批量是反过来——整条片子只解码
/// 一遍，用 `select` 挑出要的那些帧。
///
/// 实测（96 秒素材、8 核、缩到 512 宽）：
///
/// | 方式 | 墙上时间 |
/// |---|---|
/// | 逐帧 153 次，并发 8 | 16.4s |
/// | 批量一次 | 9.1s |
///
/// 两边的代价结构不同：批量的成本跟**片长**走（解码整条），逐帧的成本跟
/// **帧数**走。所以哪个划算不是一个固定数字能定的，见 [worthBatching]。
class BatchFramePlan {
  /// 升序去重后的帧号
  final List<int> frameNumbers;

  /// 请求的毫秒 → ffmpeg 输出的第几张（1 起）
  final Map<int, int> _outputIndex;

  const BatchFramePlan._(this.frameNumbers, this._outputIndex);

  bool get isEmpty => frameNumbers.isEmpty;

  /// 这个时间点对应 ffmpeg 吐出的第几张图（1 起）；不在计划里返回 null
  int? outputIndexOf(int ms) => _outputIndex[ms];

  /// `-vf select='...'` 里那段表达式。逗号要转义，否则会被 ffmpeg 当成
  /// 滤镜参数的分隔符。
  String get selectExpression =>
      frameNumbers.map((n) => r'eq(n\,' '$n)').join('+');

  static BatchFramePlan of({
    required List<int> requestedMs,
    required double fps,
  }) {
    // fps 不可信时直接给空计划：帧号会全算成 0，153 帧挤成一张，
    // 后面的编号整体错位——标签会安静地落到别的镜头上，比慢得多严重
    if (requestedMs.isEmpty || fps <= 0) {
      return const BatchFramePlan._([], {});
    }

    final numberOf = <int, int>{
      for (final ms in requestedMs) ms: (ms / 1000 * fps).round(),
    };
    final sorted = numberOf.values.toSet().toList()..sort();
    final indexOfNumber = <int, int>{
      for (var i = 0; i < sorted.length; i++) sorted[i]: i + 1,
    };
    return BatchFramePlan._(
      List.unmodifiable(sorted),
      Map.unmodifiable({
        for (final entry in numberOf.entries)
          entry.key: indexOfNumber[entry.value]!,
      }),
    );
  }

  /// 批量解码一秒素材的实测代价（96 秒片子 9.1 秒）
  static const double _secondsPerVideoSecond = 9.1 / 96;

  /// 逐帧定位单帧的实测代价（153 帧并发 8 共 16.4 秒）
  static const double _secondsPerFrame = 16.4 / 153;

  /// 值不值得为这一批帧解码整条片子。
  ///
  /// 全片打标（51 个镜头 × 3 帧）走批量；改完一个镜头重新打标只要 3 帧，
  /// 为它解码整条片子是亏的。片长未知（0）时不赌，退回逐帧。
  static bool worthBatching({
    required int frameCount,
    required int videoDurationMs,
  }) {
    if (videoDurationMs <= 0) return false;
    final batch = videoDurationMs / 1000 * _secondsPerVideoSecond;
    return frameCount * _secondsPerFrame > batch;
  }
}
