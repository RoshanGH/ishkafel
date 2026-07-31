import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/features/workbench/segment_playback.dart';

late FakePlaybackController playback;
late SegmentPlayback segment;

void _setUp({bool supportsRange = true}) {
  playback = FakePlaybackController()..supportsRange = supportsRange;
  segment = SegmentPlayback(playback);
  addTearDown(segment.dispose);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('停的动作交给播放器，不在外面轮询位置', () {
    test('把区间原样交给播放器', () async {
      _setUp();

      await segment.play(2000, 5000, 30);

      expect(playback.calls, contains('playRange(2000, 5000)'),
          reason: '在外面盯位置流判「到点了没」，采样粒度决定了它必然过头'
              '几十毫秒，再 seek 回去就是一次肉眼可见的回跳');
    });

    test('传给播放器的终点就是下一段的起点，由播放器停在它之前的最后一帧',
        () async {
      _setUp();

      // S1 = [0, 2000)，S2 从 2000 开始
      await segment.play(0, 2000, 30);

      expect(playback.calls, contains('playRange(0, 2000)'),
          reason: '半开区间：2000 属于 S2。播到它之前的最后一帧为止，'
              '正好是 S1 的最后一帧——不需要我们自己减一帧再去修正');
    });

    test('播放期间不会额外发定位指令（那正是回跳的来源）', () async {
      _setUp();
      await segment.play(2000, 5000, 30);
      playback.calls.clear();

      await _settle();

      expect(playback.calls.where((c) => c.startsWith('seekMs')), isEmpty);
    });
  });

  group('段尾自然停住时不去动播放器', () {
    test('停住（playing 变 false）后不解除区间', () async {
      _setUp();
      await segment.play(2000, 5000, 30);
      await _settle();
      playback.calls.clear();

      await playback.pause(); // 模拟播到终点后播放器自行停住
      await _settle();

      expect(playback.calls, isNot(contains('clearRange()')),
          reason: 'mpv 是以「EOF + keep-open」的形态停在终点的，这时清掉'
              '终点它会认为没有终点了而自己恢复播放——实测停在 2615ms 之后'
              '二十秒，位置已经跑到 21 秒。就让它停在那儿，真正要继续播时'
              '（PlaybackController.play）再解除');
      expect(segment.isActive, isFalse, reason: '这一段已经放完了');
    });

    test('播下一段前先解除上一段', () async {
      _setUp();
      await segment.play(0, 2000, 30);
      await _settle();
      playback.calls.clear();

      await segment.play(5000, 8000, 30);

      expect(playback.calls.indexOf('clearRange()'),
          lessThan(playback.calls.indexOf('playRange(5000, 8000)')));
    });
  });

  group('用户另有动作时立刻放手', () {
    test('cancel 会解除区间', () async {
      _setUp();
      await segment.play(2000, 5000, 30);
      await _settle();
      playback.calls.clear();

      await segment.cancel();

      expect(playback.calls, contains('clearRange()'));
      expect(segment.isActive, isFalse);
    });

    test('没在区间播放时 cancel 不发多余指令', () async {
      _setUp();

      await segment.cancel();

      expect(playback.calls, isEmpty,
          reason: '每次点刻度尺都发一条无谓的属性设置，纯属浪费');
    });
  });

  group('播放器没有区间能力时如实降级', () {
    test('从起点播，但不假装停得住', () async {
      _setUp(supportsRange: false);

      await segment.play(2000, 5000, 30);

      expect(playback.calls, containsAllInOrder(['seekMs(2000)', 'play()']));
      expect(segment.isActive, isFalse,
          reason: '停不住就别把自己标成「区间播放中」，'
              '否则后面还会去发一条解除指令');
    });
  });

  group('非法区间不发指令', () {
    test('终点不在起点之后时什么都不做', () async {
      _setUp();

      await segment.play(3000, 3000, 30);

      expect(playback.calls, isEmpty,
          reason: '零长度片段播了也只能立刻停，白闪一下不如不动');
    });
  });
}
