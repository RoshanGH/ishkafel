import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/track_plan.dart';
import 'package:ishkafel/core/script/script_track_plan.dart';

/// **一句都没进预览时，不许摆出「正在播」的样子。**
///
/// 2026-09-10 真机走查：脚本只写了台词、还没挑镜头，点「自动铺一版」
/// 配完音之后播放器被无条件 play() 了一下——预览轨其实是空的，于是屏幕上
/// 是一个暂停按钮配着 00:00 / 00:00，SnackBar 还说「铺好了，正在播」。
/// 状态跟事实对不上，人只会以为软件坏了。
void main() {
  test('全部行都被跳过时，方案是空的——调用方据此别开播', () {
    const result = ScriptPlanResult(
      plan: TrackPlan(video: [], voice: []),
      skippedLines: {0: '还没挑镜头', 1: '还没挑镜头'},
    );

    expect(result.isEmpty, isTrue,
        reason: '空方案 play() 下去，播放器会进「正在播」却停在 0');
  });

  test('有一行进得来就不算空', () {
    const result = ScriptPlanResult(
      plan: TrackPlan(
        video: [TrackSegment(atMs: 0, durationMs: 3000, source: '/v/a.mp4')],
        voice: [TrackSegment(atMs: 0, durationMs: 3000, source: '/a/1.mp3')],
      ),
      skippedLines: {1: '还没挑镜头'},
      lineStarts: {0: 0},
    );

    expect(result.isEmpty, isFalse);
  });
}
