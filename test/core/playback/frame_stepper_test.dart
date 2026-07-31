import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/frame_time.dart';
import 'package:ishkafel/core/playback/frame_stepper.dart';

const _durationMs = 96233;

late FrameStepper stepper;

void _setUp() => stepper = FrameStepper();

/// 连续步进 [times] 次，返回每次定位到的毫秒
List<int> _walk(int times,
    {int from = 0, int frames = 1, double fps = 30}) {
  final out = <int>[];
  for (var i = 0; i < times; i++) {
    out.add(stepper.nextMs(
        positionMs: from, frames: frames, fps: fps, durationMs: _durationMs));
  }
  return out;
}

void main() {
  group('逐帧步进必须一帧不落（真机反馈：走着走着卡住不动）', () {
    test('30fps 连走 12 帧，每一步都换到新的一帧', () {
      _setUp();

      final ms = _walk(12);

      expect(ms, [33, 67, 100, 133, 167, 200, 233, 267, 300, 333, 367, 400],
          reason: '在毫秒上按 +33 走的话，33+33=66 仍落在第 1 帧的显示区间 '
              '[33,67) 内，画面纹丝不动——每走三四步就必然重复一次');
      expect(ms.map((m) => frameIndex(m, 30)).toList(),
          [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
          reason: '帧序号必须严格逐一递增');
    });

    test('各帧率下连走 60 帧都不重复、不跳号', () {
      for (final fps in [24.0, 25.0, 30.0, 50.0, 59.94, 60.0]) {
        _setUp();
        final frames =
            _walk(60, fps: fps).map((m) => frameIndex(m, fps)).toList();

        expect(frames, List.generate(60, (i) => i + 1),
            reason: 'fps=$fps 出现了重复或跳号：$frames');
      }
    });

    test('倒着走同样一帧不落', () {
      _setUp();
      // 先走到第 20 帧
      _walk(20);

      final back = _walk(5, frames: -1).map((m) => frameIndex(m, 30)).toList();

      expect(back, [19, 18, 17, 16, 15]);
    });
  });

  group('按住不放连发时不依赖播放器上报的位置', () {
    test('位置一直停在 0（seek 还没生效）也照样往前走', () {
      _setUp();

      // 每次都传同一个陈旧的 positionMs，模拟播放器还没跟上
      final frames = _walk(8, from: 0).map((m) => frameIndex(m, 30)).toList();

      expect(frames, [1, 2, 3, 4, 5, 6, 7, 8],
          reason: 'seek 是异步的。每次都从播放器位置反推帧号，连发时会反复'
              '算出同一个旧帧号，于是原地踏步——这正是「按住不动它卡住」');
    });

    test('reset 之后重新以播放器位置为准', () {
      _setUp();
      _walk(10); // 锚点到第 10 帧

      stepper.reset();
      final ms = stepper.nextMs(
          positionMs: msOfFrame(50, 30),
          frames: 1,
          fps: 30,
          durationMs: _durationMs);

      expect(frameIndex(ms, 30), 51,
          reason: '用户点了刻度尺/拖了播放头之后，锚点必须作废，'
              '否则下一次步进会从早已过期的位置跳走');
    });
  });

  group('边界', () {
    test('片头再往前走停在第 0 帧，不出现负时间', () {
      _setUp();

      final ms = _walk(5, frames: -1);

      expect(ms.every((m) => m >= 0), isTrue);
      expect(ms.last, 0);
    });

    test('片尾再往后走停在最后一帧，不越过片长', () {
      _setUp();
      stepper.reset();
      final ms = stepper.nextMs(
          positionMs: _durationMs,
          frames: 100,
          fps: 30,
          durationMs: _durationMs);

      expect(ms, lessThan(_durationMs));
      expect(frameIndex(ms, 30),
          FrameSpan.fromMs(0, _durationMs, 30).last);
    });

    test('粗调（一次 10 帧）也精确落在帧点上', () {
      _setUp();

      final frames = _walk(3, frames: 10).map((m) => frameIndex(m, 30)).toList();

      expect(frames, [10, 20, 30]);
    });

    test('帧率非法时原地不动，不做除零', () {
      _setUp();

      for (final fps in [0.0, -30.0, double.nan]) {
        expect(
            stepper.nextMs(
                positionMs: 1234,
                frames: 1,
                fps: fps,
                durationMs: _durationMs),
            1234);
      }
    });

    test('片长为 0（元信息缺失）时不崩，停在第 0 帧', () {
      _setUp();

      expect(
          stepper.nextMs(
              positionMs: 0, frames: 5, fps: 30, durationMs: 0),
          0);
    });
  });
}
