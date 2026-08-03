/// 一个镜头要抽哪几帧送去做视觉理解。
///
/// **首 / 中 / 尾三帧**。单帧只能看到一个静止姿态，判不出镜头里在发生什么
/// ——实测同一镜头 3 帧给出「主播转动身体依次指向不同方向的货位」，单帧只有
/// 「主播在仓库中直播带货」。
///
/// 为什么固定三帧而不是按秒采样：按秒采样时中位 1.8 秒的镜头只抽到 2 帧，
/// 且都落在 30%/80% 处，**首尾都没覆盖到**——而一个镜头「从什么开始、到什么
/// 结束」恰恰是判断它在拍什么的关键。反过来长镜头抽到 8 帧也没有更准，
/// 只是 prompt token 线性变贵。
abstract final class ShotFrameSampler {
  /// 首尾各往里让开的毫秒数。
  ///
  /// 镜头边界那一帧常常正卡在转场中间——画面糊，或者干脆还是上一个镜头的
  /// 尾巴，代表性最差。让开 80ms（30fps 下约 2~3 帧）肉眼看还是同一个画面，
  /// 但能避开转场。
  static const int edgeInsetMs = 80;

  /// 返回要抽帧的时间点（毫秒），至少一帧，全部落在 `[startMs, endMs)` 内。
  ///
  /// 短到让不开时自动退化成中点一帧——硬凑三帧只会抽出重复的时间点，
  /// 白花一次 token。
  static List<int> sampleAt({required int startMs, required int endMs}) {
    final duration = endMs - startMs;
    if (duration <= 0) return [startMs];

    final middle = startMs + duration ~/ 2;
    final first = startMs + edgeInsetMs;
    final last = endMs - 1 - edgeInsetMs;
    // 让开之后三帧还得彼此分得开，否则会抽出重复帧
    if (first >= middle || middle >= last) return [middle];

    return List.unmodifiable([first, middle, last]);
  }
}
