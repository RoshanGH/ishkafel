import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';

/// 一段选好几首配乐，导出多条时怎么分。
///
/// 2026-09-14 用户定的：「背景音乐不参与笛卡尔积的计算，它是平分的。
/// 导出多少数量，根据有多少个背景音乐……比如导出 100 条视频，两个背景音乐
/// 的话，那就各 50 个。不能平分的话，那就一个多一个少。」
///
/// 实现是**按次序轮流**（`variantIndex % 首数`）——它天然就是平分，
/// 而且是确定性的：同一个方案导两次，第 3 条永远是同一首。
/// 随机会让人以为软件出了岔子。
BgmSegment _seg(int count) => BgmSegment(
      startUnit: 0,
      endUnit: 0,
      fit: BgmFit.loop,
      materials: [
        for (var i = 0; i < count; i++)
          BgmMaterial(
              id: i + 1, name: '第 ${i + 1} 首', durationMs: 30000,
              previewUrl: null),
      ],
    );

/// 导 [variants] 条，每首各被用了几次
Map<int, int> _spread(BgmSegment seg, int variants) {
  final out = <int, int>{};
  for (var i = 0; i < variants; i++) {
    final id = seg.materialFor(i).id;
    out[id] = (out[id] ?? 0) + 1;
  }
  return out;
}

void main() {
  test('导 100 条、2 首：各 50', () {
    expect(_spread(_seg(2), 100), {1: 50, 2: 50});
  });

  test('除不尽就一个多一个少，最多差一条', () {
    final counts = _spread(_seg(3), 100).values.toList()..sort();
    expect(counts, [33, 33, 34]);
    expect(counts.last - counts.first, lessThanOrEqualTo(1));
  });

  test('条数比首数还少：前几首各一条，其余这一批用不上', () {
    expect(_spread(_seg(4), 2), {1: 1, 2: 1});
  });

  test('只选一首：每条都是它', () {
    expect(_spread(_seg(1), 7), {1: 7});
  });

  test('确定性：同样的方案导两次，第几条用哪一首一模一样', () {
    final seg = _seg(3);
    expect([for (var i = 0; i < 10; i++) seg.materialFor(i).id],
        [for (var i = 0; i < 10; i++) seg.materialFor(i).id]);
    expect(seg.materialFor(2).id, 3);
    expect(seg.materialFor(3).id, 1, reason: '用完一轮回到头');
  });

  test('预览只放一首——★ 标的那首', () {
    final seg = BgmSegment(
      startUnit: 0,
      endUnit: 0,
      fit: BgmFit.loop,
      previewIndex: 1,
      materials: _seg(3).materials,
    );
    expect(seg.previewMaterial.id, 2);
  });

  test('删掉几首之后预览下标越界：夹回第一首，不崩', () {
    final seg = BgmSegment(
      startUnit: 0,
      endUnit: 0,
      fit: BgmFit.loop,
      previewIndex: 5,
      materials: _seg(2).materials,
    );
    expect(seg.previewMaterial.id, 1);
  });
}
