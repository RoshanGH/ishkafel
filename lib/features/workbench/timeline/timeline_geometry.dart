import '../../../core/export/composed_timeline.dart';

/// 时间线视口（不可变）：缩放与滚动状态 + ms↔px 换算。
///
/// **时间线画的是成片，不是原片。** 整体替换把一个 15.1 秒的单元换成 11.3 秒
/// 的候选之后，那一格就该窄成 11.3 秒、后面的跟着左移——用户看到的宽度就是
/// 它在成片里真实的长度。此前格子按原片画、播放头按比例走，播到格子的 3/4
/// 就跳到下一格，用户得在脑子里再换算一次才明白发生了什么。
///
/// 换算这一层内建在这里，所以**调用方一行都不用改**：传进来的、返回出去的
/// 仍然是原片毫秒（切分数据本来就按原片记），只有内部多走一次 [axis] 映射。
/// 刻度尺是唯一的例外——它标的是成片时刻，走 [composedMsToPx]。
class TimelineGeometry {
  /// 时间轴总长。有 [axis] 时是**成片**总长
  final int durationMs;
  final double msPerPx; // 缩放：每像素毫秒数（越小越放大）
  final double scrollPx; // 水平滚动（像素）

  /// 原片刻度 ↔ 成片刻度的映射。为 null 表示没有整体替换，两者相同
  final ComposedTimeline? axis;

  const TimelineGeometry({
    required this.durationMs,
    required this.msPerPx,
    this.scrollPx = 0,
    this.axis,
  });

  /// **原片**毫秒转像素坐标
  /// **已删除**：`msToPx(原片毫秒)` 走的是「原片 → 成片」换算，那个方向
  /// 是病态的——`endMs` 是开区间，换算按「谁的原片区间盖住它」找，
  /// 落进的是相邻那一段；列表顺序和原片顺序一致时恰好相等，一调序就失效。
  /// 一格在成片上的位置改用 `track_px.dart` 的 `unitPx` / `shotPx` 按**下标**问，
  /// 别的地方直接用 [composedMsToPx]。
  /// 见 `docs/2026-09-08-成片时间轴重构-TRD.md` 二、2.2。

  /// **成片**毫秒转像素坐标（刻度尺、播放头用）
  double composedMsToPx(int composedMs) => composedMs / msPerPx - scrollPx;

  /// 像素坐标转**原片**毫秒
  int pxToMs(double px) {
    final composed = pxToComposedMs(px);
    return axis?.toSourceMs(composed) ?? composed;
  }

  /// 像素坐标转**成片**毫秒，有界 [0, durationMs]
  int pxToComposedMs(double px) =>
      ((px + scrollPx) * msPerPx).round().clamp(0, durationMs);

  /// 总时长对应的像素宽度
  double get totalWidthPx => durationMs / msPerPx;

  /// 返回新实例，保留未指定字段
  TimelineGeometry copyWith({double? msPerPx, double? scrollPx}) {
    return TimelineGeometry(
      durationMs: durationMs,
      msPerPx: msPerPx ?? this.msPerPx,
      scrollPx: scrollPx ?? this.scrollPx,
      axis: axis,
    );
  }

  /// 以锚点像素位置为中心缩放（zoomFactor>1 放大）
  /// scroll 同步补偿，并 clamp 到合法范围 [0, max(0, totalWidth - viewport)]
  /// 最大放大倍数（相对 fit）。
  ///
  /// 不钳制时滚轮/捏合能一路放到几万倍，此时一帧横跨整个视口，任何操作都
  /// 失去意义；缩小方向若能缩到 fit 以下，内容右侧会空出一大片，而波形轨
  /// 用的 pxToMs 是带钳制的，那片空白会被画成一条等高实心带——看起来像
  /// 「视频结束后还有声音」。
  static const double maxZoom = 20;

  /// 当前相对 fit 的缩放倍数。滑块必须从这里反推，而不是自己维护历史值：
  /// 否则滚轮缩放后滑块仍停在旧值，下一次拖滑块会以错误基准算 factor，
  /// 出现「往左拖想缩小、画面反而放大」。
  double zoomLevel({required double viewportWidthPx}) {
    if (viewportWidthPx <= 0 || msPerPx <= 0) return 1;
    return (durationMs / viewportWidthPx) / msPerPx;
  }

  TimelineGeometry zoomAt(double anchorPx, double zoomFactor, {required double viewportWidthPx}) {
    // 锚点对应的时间（毫秒）
    final anchorMs = pxToMs(anchorPx);
    // 新的缩放系数，钳制在 [fit, fit/maxZoom] 之间
    final fitMsPerPx =
        viewportWidthPx > 0 ? durationMs / viewportWidthPx : msPerPx;
    final newMsPerPx =
        (msPerPx / zoomFactor).clamp(fitMsPerPx / maxZoom, fitMsPerPx);
    // 计算新的 scrollPx 使得锚点时间在 anchorPx 处
    final newScrollPx = anchorMs / newMsPerPx - anchorPx;
    // 新的总宽度
    final newTotalWidthPx = durationMs / newMsPerPx;
    // clamp 到合法范围
    final maxScroll = (newTotalWidthPx - viewportWidthPx).clamp(0.0, double.infinity);
    final clampedScrollPx = newScrollPx.clamp(0.0, maxScroll);

    return TimelineGeometry(
      durationMs: durationMs,
      msPerPx: newMsPerPx,
      scrollPx: clampedScrollPx,
      axis: axis,
    );
  }

  /// 滚动并 clamp 到 [0, max(0, totalWidth - viewport)]
  TimelineGeometry scrolledBy(double deltaPx, {required double viewportWidthPx}) {
    final newScrollPx = scrollPx + deltaPx;
    final maxScroll = (totalWidthPx - viewportWidthPx).clamp(0.0, double.infinity);
    final clampedScrollPx = newScrollPx.clamp(0.0, maxScroll);

    return TimelineGeometry(
      durationMs: durationMs,
      msPerPx: msPerPx,
      scrollPx: clampedScrollPx,
      axis: axis,
    );
  }

  /// 适配整个时长到给定视口宽（初始状态）
  /// 视口宽度变化后的新几何。
  ///
  /// 分两种情形，因为用户的意图完全不同：
  /// - **适应窗口（缩放 = 1）**：他要的就是「一屏看全片」，窗口变大变小都
  ///   该继续铺满。之前这里只 clamp 了滚动、没重算 msPerPx，窗口一拉宽，
  ///   时间线还是原来那么长，右边空一大块。
  /// - **已经放大过**：他正盯着某一段看，保持缩放倍数，只把滚动夹回合法
  ///   范围。跟着重新 fit 会把他的视野一把拉回全片，等于清掉工作状态。
  TimelineGeometry resizedTo({
    required double oldViewportWidthPx,
    required double newViewportWidthPx,
  }) {
    if (newViewportWidthPx <= 0) return this;
    // 首次布局（旧宽度为 0）没有可比较的基准，按适应窗口处理
    final wasFit = oldViewportWidthPx <= 0 ||
        zoomLevel(viewportWidthPx: oldViewportWidthPx) <= 1.0001;
    return wasFit
        ? TimelineGeometry.fit(
            durationMs: durationMs,
            viewportWidthPx: newViewportWidthPx,
            axis: axis)
        : scrolledBy(0, viewportWidthPx: newViewportWidthPx);
  }

  /// 换一套成片时间轴（整体替换的候选变了/时长探出来了），**保持缩放与
  /// 滚动**——用户改了个候选就被弹回片头是不能接受的
  TimelineGeometry withAxis(ComposedTimeline? next) {
    final total = next?.totalMs ?? durationMs;
    if (total <= 0) return this;
    return TimelineGeometry(
      durationMs: total,
      msPerPx: msPerPx,
      scrollPx: scrollPx,
      axis: next,
    );
  }

  static TimelineGeometry fit({
    required int durationMs,
    required double viewportWidthPx,
    ComposedTimeline? axis,
  }) {
    final total = axis?.totalMs ?? durationMs;
    final msPerPx = total / viewportWidthPx;
    return TimelineGeometry(
      durationMs: total,
      msPerPx: msPerPx,
      scrollPx: 0,
      axis: axis,
    );
  }

  /// 刻度间隔选择：返回不小于 minLabelSpacingPx 像素间距的"整"毫秒步长
  /// 档位：1s/2s/5s/10s/30s/60s
  int rulerStepMs({double minLabelSpacingPx = 80}) {
    const steps = [1000, 2000, 5000, 10000, 30000, 60000];

    for (final step in steps) {
      final pxSpacing = step / msPerPx;
      if (pxSpacing >= minLabelSpacingPx) {
        return step;
      }
    }

    // 全部超出，返回最大档位
    return 60000;
  }
}
