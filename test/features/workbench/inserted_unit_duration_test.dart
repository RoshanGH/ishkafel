import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/inserted_unit_label.dart';

/// 手加的单元，属性栏该显示多长。
///
/// 真机 bug（2026-09-07）：它写死 10.00s——那是加进来时给的占位，
/// 而时间线上画的是挑到的素材的真实长度。同一个东西两处说法不一样，
/// 人只会以为哪儿算错了。
void main() {
  group('手加的单元', () {
    test('挑了素材：显示素材的真实长度', () {
      expect(unitDurationLabel(placeholderMs: 10000, composedMs: 3400,
              hasSource: false),
          '3.40s');
    });

    test('还没挑素材：说「待填」，不报那个编出来的 10 秒', () {
      expect(
          unitDurationLabel(
              placeholderMs: 10000, composedMs: null, hasSource: false),
          '待填',
          reason: '10 秒是加进来时给的占位，不是任何真实的长度——'
              '报出去人会照着它规划片长');
    });
  });

  group('分析切出来的单元', () {
    test('照常报它自己的长度', () {
      expect(
          unitDurationLabel(
              placeholderMs: 15300, composedMs: null, hasSource: true),
          '15.30s');
    });

    test('被整体替换过就报成片里的长度——时间线画的就是这个', () {
      expect(
          unitDurationLabel(
              placeholderMs: 22500, composedMs: 16300, hasSource: true),
          '16.30s');
    });
  });
}
