import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/shot_frame_sampler.dart';

List<int> _at(int startMs, int endMs) =>
    ShotFrameSampler.sampleAt(startMs: startMs, endMs: endMs);

void main() {
  group('按秒采样', () {
    test('2.6 秒的镜头抽 3 帧', () {
      final frames = _at(0, 2633);

      expect(frames, hasLength(3));
    });

    test('不足一秒的镜头抽 1 帧，取中点', () {
      final frames = _at(1000, 1400);

      expect(frames, [1200]);
    });

    test('帧都落在镜头区间内，不越界到相邻镜头', () {
      for (final (s, e) in [(0, 2633), (2633, 3933), (5967, 9100), (0, 96233)]) {
        for (final f in _at(s, e)) {
          expect(f, greaterThanOrEqualTo(s), reason: '[$s,$e) 抽到了区间之前');
          expect(f, lessThan(e), reason: '[$s,$e) 抽到了下一个镜头');
        }
      }
    });

    test('首帧不取边界那一帧', () {
      final frames = _at(0, 5000);

      expect(frames.first, greaterThan(0),
          reason: '镜头边界那一帧常常正处在转场中间（画面糊、或还是上一个'
              '镜头的尾巴），代表性最差');
    });

    test('时间点严格递增', () {
      final frames = _at(0, 8000);

      for (var i = 1; i < frames.length; i++) {
        expect(frames[i], greaterThan(frames[i - 1]));
      }
    });
  });

  group('长镜头设上限', () {
    test('40 秒的单元不会抽 40 帧', () {
      final frames = _at(0, 40000);

      expect(frames, hasLength(ShotFrameSampler.maxFrames),
          reason: 'prompt token 随帧数线性增长，40 帧既贵又慢，'
              '而判断「这个镜头拍什么」用不到这么多样本');
    });

    test('超上限时仍然覆盖整段，不是只看开头', () {
      final frames = _at(0, 40000);

      expect(frames.first, lessThan(4000));
      expect(frames.last, greaterThan(36000),
          reason: '只取前 8 秒的话，后面 32 秒等于没看');
    });
  });

  group('边界情况', () {
    test('零长度或负长度不崩，给一帧', () {
      expect(_at(1000, 1000), [1000]);
      expect(_at(1000, 500), [1000]);
    });

    test('真实素材的每个镜头都至少一帧', () {
      // XCT 的 U1 五个镜头
      const bounds = [0, 2633, 3933, 5967, 9100, 14567];
      for (var i = 0; i + 1 < bounds.length; i++) {
        expect(_at(bounds[i], bounds[i + 1]), isNotEmpty);
      }
    });
  });
}
