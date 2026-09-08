import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_edit_ops.dart';

/// **±N 帧要真的走 N 帧，不是走 N×33 毫秒。**
///
/// 帧点在毫秒轴上是非等距的（30fps 下 0,33,67,100…，间距在 33/34 交替）。
/// 拿 `round(1000/fps)` 当步长再吸附回帧点，走得多了就会少走一帧：
/// 30 步 × 33ms = 990ms，而 30 帧是 1000ms。
/// 而且 `round(1000/29.97)` 和 `round(1000/30)` 都是 33，两种帧率分不开。
void main() {
  group('30fps', () {
    test('走 1 帧就是下一个帧点', () {
      expect(SegmentationEditOps.msAfterFrames(0, 30, 1), 33);
      expect(SegmentationEditOps.msAfterFrames(33, 30, 1), 67);
    });

    test('走 30 帧正好一秒——按 33ms 一步会停在 990', () {
      expect(SegmentationEditOps.msAfterFrames(0, 30, 30), 1000);
    });

    test('走 1800 帧正好一分钟', () {
      expect(SegmentationEditOps.msAfterFrames(0, 30, 1800), 60000);
    });

    test('反向也对', () {
      expect(SegmentationEditOps.msAfterFrames(1000, 30, -30), 0);
      expect(SegmentationEditOps.msAfterFrames(67, 30, -1), 33);
    });

    test('起点不在帧点上时，先吸到最近的帧再走', () {
      expect(SegmentationEditOps.msAfterFrames(35, 30, 0), 33);
      expect(SegmentationEditOps.msAfterFrames(35, 30, 1), 67);
    });
  });

  group('60fps：步长更小，不能被 30fps 的常数带偏', () {
    test('走 60 帧一秒', () {
      expect(SegmentationEditOps.msAfterFrames(0, 60, 60), 1000);
    });

    test('走 1 帧是 17ms（round(1000/60)=17，但真实间距在 16/17 交替）', () {
      expect(SegmentationEditOps.msAfterFrames(0, 60, 1), 17);
      expect(SegmentationEditOps.msAfterFrames(17, 60, 1), 33);
    });
  });

  group('不许走到负数', () {
    test('片头再往前退还是 0', () {
      expect(SegmentationEditOps.msAfterFrames(0, 30, -5), 0);
    });
  });
}
