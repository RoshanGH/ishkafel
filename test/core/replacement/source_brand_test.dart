import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/brand_consistency.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';

/// 「候选之间打架」这个判据有个缺口：**一条片子的候选全是若也**（而原片是
/// 滴露）时，候选之间毫无冲突，可整条片子都错了。
///
/// 补上参照——原片自己的产品露出镜头。分析打标时本来就在看图，顺手记下
/// 每一镜露的是谁家产品，不额外花钱。
void main() {
  Shot shot(String? brand) =>
      Shot(startMs: 0, endMs: 1000, productBrand: brand);

  List<SemanticUnit> units(List<Shot> shots) => [
        SemanticUnit(
            index: 0, startMs: 0, endMs: 1000, transcript: '', shots: shots),
      ];

  PickedMaterial m(int id, String brand) => PickedMaterial(
      id: id, name: 'm$id', burnedText: const [], productBrand: brand);

  test('原片露的是什么牌子：按出现最多的那个算', () {
    expect(
      sourceBrandOf(units([shot('滴露'), shot('滴露'), shot(null), shot('若也')])),
      '滴露',
    );
  });

  test('原片一个产品镜头都没有：说不出品牌，返回 null', () {
    expect(sourceBrandOf(units([shot(null), shot(null)])), isNull);
  });

  test('还没打过标（老任务）：也返回 null，不瞎猜', () {
    expect(sourceBrandOf(const []), isNull);
  });

  test('候选全是别家的：候选之间不打架，但和原片对不上——要报', () {
    final text = brandMismatchNotice(
      picked: [m(1, '若也 Rove'), m(2, '若也 Rove')],
      sourceBrand: '滴露',
    )!;
    expect(text, contains('滴露'));
    expect(text, contains('若也 Rove'));
  });

  test('候选和原片是同一个牌子：不打扰', () {
    expect(
      brandMismatchNotice(picked: [m(1, '滴露 Dettol')], sourceBrand: '滴露'),
      isNull,
    );
  });

  test('说不出原片品牌时不报——不知道不等于错', () {
    expect(
      brandMismatchNotice(picked: [m(1, '若也')], sourceBrand: null),
      isNull,
    );
  });

  test('纯场景素材不背这个锅', () {
    expect(
      brandMismatchNotice(
        picked: const [PickedMaterial(id: 1, name: 'a', burnedText: [])],
        sourceBrand: '滴露',
      ),
      isNull,
    );
  });
}
