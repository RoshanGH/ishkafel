import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/shot_frame_sampler.dart';

List<int> _at(int startMs, int endMs) =>
    ShotFrameSampler.sampleAt(startMs: startMs, endMs: endMs);

void main() {
  group('首 / 中 / 尾三帧', () {
    test('常规镜头恰好三帧', () {
      expect(_at(0, 2633), hasLength(3));
      expect(_at(0, 40000), hasLength(3),
          reason: '再长也是三帧——判断「这个镜头拍什么」用不到更多样本，'
              'prompt token 却随帧数线性涨');
    });

    test('三帧分别贴着头、中、尾', () {
      final frames = _at(0, 10000);

      expect(frames[0], lessThan(1000), reason: '第一帧要能代表开头');
      expect(frames[1], inInclusiveRange(4500, 5500), reason: '第二帧在中点');
      expect(frames[2], greaterThan(9000), reason: '第三帧要能代表结尾');
    });

    test('首尾各让开一点，不取边界那一帧', () {
      final frames = _at(0, 10000);

      expect(frames.first, greaterThan(0),
          reason: '镜头边界那一帧常常正卡在转场中间——画面糊，或者还是上一个'
              '镜头的尾巴，代表性最差');
      expect(frames.last, lessThan(9999));
    });

    test('让开的幅度是小常数，不会把首尾让到中间去', () {
      final frames = _at(0, 10000);

      expect(frames.first, lessThan(ShotFrameSampler.edgeInsetMs * 2 + 1));
      expect(10000 - frames.last,
          lessThan(ShotFrameSampler.edgeInsetMs * 2 + 1));
    });
  });

  group('短镜头退化', () {
    test('短到让不开时不再硬凑三帧，也不越界', () {
      for (final (s, e) in [(0, 400), (1000, 1100), (5000, 5001)]) {
        final frames = _at(s, e);
        expect(frames, isNotEmpty);
        for (final f in frames) {
          expect(f, greaterThanOrEqualTo(s), reason: '[$s,$e) 抽到了区间之前');
          expect(f, lessThan(e), reason: '[$s,$e) 抽到了下一个镜头');
        }
      }
    });

    test('极短镜头取中点一帧', () {
      expect(_at(1000, 1100), [1050]);
    });

    test('时间点严格递增、不重复', () {
      for (final (s, e) in [(0, 800), (0, 2000), (0, 10000), (2633, 3733)]) {
        final frames = _at(s, e);
        for (var i = 1; i < frames.length; i++) {
          expect(frames[i], greaterThan(frames[i - 1]),
              reason: '[$s,$e) 抽出了重复帧，等于白花一次 token');
        }
      }
    });
  });

  group('边界情况', () {
    test('零长度或负长度不崩，给一帧', () {
      expect(_at(1000, 1000), [1000]);
      expect(_at(1000, 500), [1000]);
    });

    test('真实素材的每个镜头都至少一帧且都在区间内', () {
      // XCT 的 U1 五个镜头
      const bounds = [0, 2633, 3933, 5967, 9100, 14567];
      for (var i = 0; i + 1 < bounds.length; i++) {
        final frames = _at(bounds[i], bounds[i + 1]);
        expect(frames, isNotEmpty);
        expect(frames.first, greaterThanOrEqualTo(bounds[i]));
        expect(frames.last, lessThan(bounds[i + 1]));
      }
    });
  });
}
