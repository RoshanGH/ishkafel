import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/editing/frame_time.dart';
import 'package:ishkafel/features/workbench/segment_playback.dart';

const _fps = 30.0;

late FakePlaybackController playback;
late SegmentPlayback segment;

void _setUp() {
  playback = FakePlaybackController();
  segment = SegmentPlayback(playback);
  addTearDown(segment.dispose);
}

/// 模拟播放器把位置推进到 [ms]
Future<void> _positionTo(int ms) async {
  await playback.seekMs(ms);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('双击一块 → 只播这一块', () {
    test('从起点开始播', () async {
      _setUp();

      await segment.play(2000, 5000, _fps);

      expect(playback.calls, containsAllInOrder(['seekMs(2000)', 'play()']));
    });

    test('走到终点自动暂停', () async {
      _setUp();
      await segment.play(2000, 5000, _fps);
      playback.calls.clear();

      await _positionTo(3000);
      expect(playback.calls, isNot(contains('pause()')),
          reason: '还没到终点就停，等于只播了半截');

      await _positionTo(5000);
      expect(playback.calls, contains('pause()'));
    });

    test('停在这一段的最后一帧，不是下一段的第一帧', () async {
      _setUp();
      await segment.play(2000, 5000, _fps);
      playback.calls.clear();

      // 位置回调是离散采样的，触发时往往已经越过终点
      await _positionTo(5080);

      final lastFrame = lastFrameBefore(5000, _fps);
      expect(lastFrame, lessThan(5000));
      expect(playback.calls, contains('seekMs($lastFrame)'),
          reason: '相邻片段无缝覆盖，5000ms 就是下一段的第一帧。'
              '停在那里等于双击 S1 却看到 S2 的画面；何况位置回调本身会'
              '越过终点几十毫秒，不拉回来连「停在交界」都保证不了');
    });

    test('先暂停再定位，不会在拉回途中又往前播一截', () async {
      _setUp();
      await segment.play(2000, 5000, _fps);
      playback.calls.clear();

      await _positionTo(5080);

      final pauseAt = playback.calls.indexOf('pause()');
      final seekAt = playback.calls
          .indexWhere((c) => c.startsWith('seekMs(${lastFrameBefore(5000, _fps)}'));
      expect(pauseAt, isNonNegative);
      expect(seekAt, greaterThan(pauseAt));
    });

    test('停过一次之后不再重复暂停', () async {
      _setUp();
      await segment.play(2000, 5000, _fps);
      await _positionTo(5000);
      playback.calls.clear();

      await _positionTo(5200);

      expect(playback.calls, isNot(contains('pause()')),
          reason: '监听没撤掉的话，用户手动再播时会被反复摁停');
    });

    test('seek 后残留的旧位置不会立刻把新片段掐停', () async {
      _setUp();
      // 先让播放器停在很靠后的位置
      await _positionTo(9000);

      await segment.play(1000, 3000, _fps);
      await Future<void>.delayed(Duration.zero);
      playback.calls.clear();
      await _positionTo(1200);

      expect(playback.calls, isNot(contains('pause()')),
          reason: 'seek 生效前播放器还会报几次旧位置（9000 > 3000），'
              '不设防就会「刚双击就停」');
    });

    test('播下一段前先撤掉上一段的监听', () async {
      _setUp();
      await segment.play(0, 2000, _fps);
      await segment.play(5000, 8000, _fps);
      playback.calls.clear();

      // 走到第一段的终点：那一段已经作废，不该有任何反应
      await _positionTo(2000);
      expect(playback.calls, isNot(contains('pause()')));

      await _positionTo(8000);
      expect(playback.calls, contains('pause()'));
    });
  });

  group('用户另有动作时立刻放手', () {
    test('cancel 之后走到终点不再暂停', () async {
      _setUp();
      await segment.play(2000, 5000, _fps);
      await _positionTo(2100);
      segment.cancel();
      playback.calls.clear();

      await _positionTo(5000);

      expect(playback.calls, isNot(contains('pause()')),
          reason: '用户已经自己拖走 / 按了空格，这一段的约束就该失效——'
              '否则播到某个位置会莫名其妙地停下');
    });
  });

  group('非法区间不发指令', () {
    test('终点不在起点之后时什么都不做', () async {
      _setUp();

      await segment.play(3000, 3000, _fps);

      expect(playback.calls, isEmpty,
          reason: '零长度片段播了也只能立刻停，白闪一下不如不动');
    });
  });
}
