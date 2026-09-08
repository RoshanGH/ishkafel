import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/features/workbench/timeline/thumbs_span.dart';

/// 胶片条铺在**原片**上，不是铺在成片总长上。
///
/// 真机 bug（2026-09-07）：手动加了一个单元（原片上没有它，占 10 秒占位）
/// 并拖到最前面之后，画面轨的缩略图整条错位——它们代表的是原片 0~49.7s 的
/// 画面，代码却拿「成片总长」去等分，再把结果当成原片时间映射一次，错了两道。
///
/// 手加的那一段**原片上根本没有画面**，那一段本就不该有缩略图。
SemanticUnit _u(int index, int start, int end, {bool hasSource = true}) =>
    SemanticUnit(
      index: index,
      startMs: start,
      endMs: end,
      transcript: '',
      hasSource: hasSource,
    );

void main() {
  test('原片跨度 = 有原片来源的那些单元的最大终点', () {
    // 原片 0~9000；手加的那个占位在 9000~19000
    final units = [
      _u(0, 9000, 19000, hasSource: false),
      _u(1, 0, 4000),
      _u(2, 4000, 9000),
    ];

    expect(sourceSpanMs(units), 9000,
        reason: '手加的那 10 秒不是原片的一部分，不能算进胶片条的跨度');
  });

  test('没有手加单元时就是全片', () {
    expect(sourceSpanMs([_u(0, 0, 4000), _u(1, 4000, 9000)]), 9000);
  });

  test('顺序被拖乱也认得出来——按最大终点算，不是拿最后一个', () {
    final units = [_u(0, 4000, 9000), _u(1, 0, 4000)];

    expect(sourceSpanMs(units), 9000);
  });

  test('一个有原片的单元都没有（空白任务）：跨度为 0，别画胶片条', () {
    expect(sourceSpanMs([_u(0, 0, 10000, hasSource: false)]), 0);
    expect(sourceSpanMs(const []), 0);
  });
}
