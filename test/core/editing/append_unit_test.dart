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
}
