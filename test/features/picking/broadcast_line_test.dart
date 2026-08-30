import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/features/picking/burned_text_warning.dart';

/// 播报条一行就那么宽（超出直接省略号）。托盘和导出页可以摆多行细节，
/// **播报只有一句话的余地**——那一句得说清「出了什么事、多严重」，
/// 细节留给人自己去那两处看。
void main() {
  PickedMaterial m(int id, {List<String>? burned, String? brand}) =>
      PickedMaterial(
          id: id,
          name: 'm$id',
          burnedText: burned ?? const [],
          productBrand: brand,
          framesSeen: 3);

  test('烧字：说清几条、什么后果，一句话之内', () {
    final line = burnedTextBroadcastLine([
      m(1, burned: ['冰冰凉凉的好舒服呀']),
      m(2, burned: ['已售罄']),
      m(3),
    ])!;
    expect(line, contains('2'));
    expect(line, contains('两层字'));
    expect(line.length, lessThan(40), reason: '播报条一行放不下长句');
  });

  test('都干净就不播——没事也说一句只会淹掉真有事那句', () {
    expect(burnedTextBroadcastLine([m(1), m(2)]), isNull);
  });

  test('品牌：说清是哪两个牌子打架', () {
    final line = brandBroadcastLine(
        picked: [m(1, brand: '滴露'), m(2, brand: '若也 Rove')],
        sourceBrand: null)!;
    expect(line, contains('滴露'));
    expect(line, contains('若也 Rove'));
    expect(line.length, lessThan(46));
  });

  test('品牌：候选全跑到别家去了，要说出原片是什么牌子', () {
    final line = brandBroadcastLine(
        picked: [m(1, brand: '若也 Rove')], sourceBrand: '滴露')!;
    expect(line, contains('滴露'));
    expect(line, contains('若也 Rove'));
  });

  test('品牌一致就不播', () {
    expect(
        brandBroadcastLine(
            picked: [m(1, brand: '滴露 Dettol')], sourceBrand: '滴露'),
        isNull);
  });

  test('牌子太多时不把整行撑爆', () {
    final line = brandBroadcastLine(picked: [
      for (var i = 0; i < 6; i++) m(i, brand: '牌子$i'),
    ], sourceBrand: null)!;
    expect(line.length, lessThan(46));
  });
}
