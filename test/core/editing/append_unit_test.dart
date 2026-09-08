import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_edit_ops.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';

SemanticUnit _u(int index, int start, int end) => SemanticUnit(
      index: index,
      startMs: start,
      endMs: end,
      transcript: 'U${index + 1}',
    );

void main() {
  group('有原片的任务也能加单元', () {
    test('接在末尾，标成「原片上没有它」', () {
      final units = [_u(0, 0, 5000), _u(1, 5000, 9000)];

      final next = SegmentationEditOps.appendUnit(units);

      expect(next.length, 3);
      expect(next.last.hasSource, isFalse,
          reason: '原片上没有这一段——导出、抽帧、原声都得知道，不能当成原片的一段去读');
      expect(next.last.startMs, 9000, reason: '时间轴上接着上一个，不留缝');
      expect(next.last.index, 2);
    });

    test('原有单元一个都不动', () {
      final units = [_u(0, 0, 5000), _u(1, 5000, 9000)];

      final next = SegmentationEditOps.appendUnit(units);

      expect(next[0].startMs, 0);
      expect(next[0].endMs, 5000);
      expect(next[1].endMs, 9000);
      expect(next.take(2).every((u) => u.hasSource), isTrue);
    });

    test('新单元没有台词、没有镜头——它们本来就不存在', () {
      final next = SegmentationEditOps.appendUnit([_u(0, 0, 5000)]);

      expect(next.last.transcript, isEmpty);
      expect(next.last.shots, isEmpty);
    });

    test('空列表也能加第一个', () {
      final next = SegmentationEditOps.appendUnit(const []);

      expect(next.single.startMs, 0);
      expect(next.single.hasSource, isFalse);
    });

    test('分析切出来的单元默认就是有原片来源的', () {
      expect(_u(0, 0, 5000).hasSource, isTrue,
          reason: '存量任务反序列化回来不能突然变成「没有原片」');
    });
  });

  group('手加单元的长度按整帧对齐', () {
    // 不对齐的话，这个零头会跟着往后每一段的成片位置一路传下去，拼到片尾
    // 越差越多——而界面显示的是帧，人看到的就是「每段都对，加起来差一帧」。
    test('29.97fps：占位长度吸到帧边界上', () {
      final units = SegmentationEditOps.appendUnit(const [], fps: 29.97);
      final added = units.single;

      final frames = added.durationMs * 29.97 / 1000;

      expect((frames - frames.round()).abs(), lessThan(0.001),
          reason: '${added.durationMs}ms 在 29.97fps 下是 $frames 帧，不是整数');
    });

    test('30fps：10 秒正好 300 帧，长度不变', () {
      final units = SegmentationEditOps.appendUnit(const [], fps: 30);

      expect(units.single.durationMs,
          SegmentationEditOps.appendedUnitPlaceholderMs);
    });

    test('不给 fps 时保持原样——老调用点不该因此变一下', () {
      final units = SegmentationEditOps.appendUnit(const []);

      expect(units.single.durationMs,
          SegmentationEditOps.appendedUnitPlaceholderMs);
    });
  });
}
