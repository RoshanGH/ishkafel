import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/brand_consistency.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';

/// 产品露出镜头**不能跨品牌换**：台词说「滴露新款消毒液」而画面是若也
/// 洗发水直播间，片子自己打自己的脸。2026-08-28 真机上就这样交付过一条。
///
/// 判据不需要知道「本片是什么品牌」——**一条片子里出现两个牌子，本身就是
/// 错的**。这个信号立刻可用，不依赖原片重打标。
void main() {
  PickedMaterial m(int id, String? brand) =>
      PickedMaterial(id: id, name: 'm$id', burnedText: const [], productBrand: brand);

  test('都是同一个牌子：没事', () {
    expect(brandConflict([m(1, '滴露'), m(2, '滴露')]), isNull);
  });

  test('两个不同的牌子：点名是哪几条', () {
    final c = brandConflict([m(1, '滴露'), m(2, '若也 Rove')])!;
    expect(c.brands, containsAll(['滴露', '若也 Rove']));
    expect(c.materialsOf('若也 Rove'), [2]);
  });

  test('纯场景镜头（没有产品露出）不参与判断', () {
    expect(brandConflict([m(1, '滴露'), m(2, null), m(3, null)]), isNull);
  });

  test('还没查过的不参与判断——不知道不等于冲突', () {
    expect(
      brandConflict([m(1, '滴露'), const PickedMaterial(id: 2, name: 'b')]),
      isNull,
    );
  });

  test('中英混写算同一个牌子——模型给的名字不稳定', () {
    expect(brandConflict([m(1, '滴露'), m(2, '滴露 Dettol'), m(3, 'Dettol')]),
        isNull);
  });

  test('大小写和空格不算区别', () {
    expect(brandConflict([m(1, 'Rove'), m(2, ' rove ')]), isNull);
  });

  test('三个牌子也都要说出来，不是只说前两个', () {
    final c = brandConflict([m(1, '滴露'), m(2, '若也'), m(3, '蓝月亮')])!;
    expect(c.brands.length, 3);
  });

  test('话术要点名品牌和素材，并说清后果', () {
    final text = brandConflictNotice([m(1, '滴露'), m(2, '若也 Rove')])!;
    expect(text, contains('滴露'));
    expect(text, contains('若也 Rove'));
    expect(text, contains('2'));
    // 说清为什么这是问题，不是只报一个「不一致」
    expect(text, anyOf(contains('台词'), contains('品牌')));
  });

  test('没冲突时不啰嗦', () {
    expect(brandConflictNotice([m(1, '滴露')]), isNull);
  });
}
