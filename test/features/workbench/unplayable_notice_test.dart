import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/track_plan.dart';

/// **还没挑素材的那几段，要在人按播放之前就说清楚。**
///
/// 2026-09-08 真机，用户原话：「你不是应该提醒吗？你不要觉得这个东西就一定要
/// 解决，你提醒他就好了呀。你必须得选个视频，他这个部分才能播放。」
void main() {
  group('成片总长要含放不了的那几段', () {
    test('只按画面轨算的话末尾比时间线短一截', () {
      const plan = TrackPlan(
        video: [TrackSegment(atMs: 0, durationMs: 20000, source: '/v/a.mp4')],
        unplayable: [
          UnplayableSpan(unitIndex: 1, startMs: 20000, endMs: 30000)
        ],
        composedTotalMs: 30000,
      );

      expect(plan.totalMs, 30000,
          reason: '真机上这里是 20000——时间线画到 01:46，播放器只到 01:36');
    });

    test('没有放不了的段时，还是按画面轨末尾算', () {
      const plan = TrackPlan(
        video: [TrackSegment(atMs: 0, durationMs: 20000, source: '/v/a.mp4')],
        composedTotalMs: 20000,
      );

      expect(plan.totalMs, 20000);
    });
  });

  group('区间命中', () {
    const span = UnplayableSpan(unitIndex: 0, startMs: 1000, endMs: 3000);

    test('区间内命中，起点算、终点不算', () {
      expect(span.covers(1000), isTrue);
      expect(span.covers(2999), isTrue);
      expect(span.covers(3000), isFalse,
          reason: '终点就是下一段的起点，两段都命中的话会在边界上反复弹提示');
      expect(span.covers(999), isFalse);
    });
  });
}
