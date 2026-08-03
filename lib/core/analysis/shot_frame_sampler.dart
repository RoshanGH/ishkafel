/// 一个镜头要抽哪几帧送去做视觉理解。
///
/// 沿用视频理解的通行做法：**按秒采样**。单帧只能看到一个静止姿态，判不出
/// 镜头里在发生什么——实测同一镜头 3 帧给出「主播转动身体依次指向不同方向
/// 的货位」，单帧只有「主播在仓库中直播带货」。
abstract final class ShotFrameSampler {
  /// 采样间隔：每秒一帧
  static const int intervalMs = 1000;

  /// 单个镜头的帧数上限。
  ///
  /// 实测 prompt token 大致随帧数线性增长（3 帧约 3980，单帧约 1377），
  /// 而一个 40 秒的单元按每秒一帧就是 40 帧——既贵又慢，边际收益却很低：
  /// 判断「这个镜头拍什么」用不到这么多样本。超过上限时改为**均匀采样**，
  /// 仍然覆盖整段而不是只看开头。
  static const int maxFrames = 8;

  /// 返回要抽帧的时间点（毫秒），至少一帧。
  ///
  /// 首帧不取 `startMs` 本身而是往里让半个采样间隔：镜头边界那一帧常常正处
  /// 在转场中间（画面糊、或还是上一个镜头的尾巴），代表性最差。
  static List<int> sampleAt({required int startMs, required int endMs}) {
    final duration = endMs - startMs;
    if (duration <= 0) return [startMs];

    final wanted = (duration / intervalMs).ceil().clamp(1, maxFrames);
    if (wanted == 1) return [startMs + duration ~/ 2];

    // 把 [start, end) 均分成 wanted 段，取每段中点
    final step = duration / wanted;
    return List.unmodifiable([
      for (var i = 0; i < wanted; i++)
        startMs + (step * (i + 0.5)).round().clamp(0, duration - 1),
    ]);
  }
}
