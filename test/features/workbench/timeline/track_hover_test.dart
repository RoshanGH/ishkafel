import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';

/// 轨道操作说明改成「停上去才出」，靠这个函数认人。
///
/// 2026-09-09 设计走查：四条轨的标题后面各挂一句灰色说明常驻着
/// （「拖两端改长度，点 × 删除」之类），一屏四行，眼睛先读到的是操作说明
/// 而不是内容——而这些话读一次就够了。
void main() {
  test('落在轨体上认得出是哪条', () {
    expect(TimelineTracks.trackLabelTopAt(TimelineTracks.unitsTop + 2),
        TimelineTracks.unitsLabelTop);
    expect(TimelineTracks.trackLabelTopAt(TimelineTracks.shotsTop + 2),
        TimelineTracks.shotsLabelTop);
    expect(TimelineTracks.trackLabelTopAt(TimelineTracks.bgmTop + 2),
        TimelineTracks.bgmLabelTop);
    expect(TimelineTracks.trackLabelTopAt(TimelineTracks.waveTop + 2),
        TimelineTracks.waveLabelTop);
  });

  test('落在标题条上也算这条轨——不然鼠标往说明上挪，说明自己就没了', () {
    expect(TimelineTracks.trackLabelTopAt(TimelineTracks.subsLabelTop + 1),
        TimelineTracks.subsLabelTop);
  });

  test('落在轨与轨之间的缝里不算任何一条', () {
    // gap 落在上一条的底边和下一条的标题条之间
    expect(TimelineTracks.trackLabelTopAt(TimelineTracks.unitsBottom + 1),
        isNull);
  });

  test('刻度区不算任何一条轨', () {
    expect(TimelineTracks.trackLabelTopAt(2), isNull);
  });

  test('每条轨都认得，一条不漏', () {
    final seen = <double>{};
    for (var dy = 0.0; dy < TimelineTracks.totalHeight; dy += 1) {
      final top = TimelineTracks.trackLabelTopAt(dy);
      if (top != null) seen.add(top);
    }

    expect(seen, hasLength(6), reason: '六条轨都要能被停到');
  });
}
