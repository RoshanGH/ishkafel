import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/frame_check.dart';

/// 看一眼素材画面，一次问清两件**只有看图才知道、而且都能毁掉整片**的事：
///
/// 1. 画面上烧着字没有——换上去还要再烧一行台词字幕，两层字叠一起
/// 2. 画面里露出的是谁家的产品——台词说「滴露新款消毒液」而画面是若也
///    洗发水直播间，片子自己打自己的脸（2026-08-28 真机交付过这种片子）
///
/// **一次调用问两件事**，不是两次：多问一个问题几乎不加钱，多跑一次调用
/// 是成倍的。
void main() {
  test('两件事一起答', () {
    final c = parseFrameCheck(
        '{"burnedText":["已售罄"],"productBrand":"若也 Rove"}');
    expect(c.burnedText, ['已售罄']);
    expect(c.productBrand, '若也 Rove');
    expect(c.hasProduct, isTrue);
  });

  test('画面里没有产品露出：品牌为 null，不是空字符串', () {
    final c = parseFrameCheck('{"burnedText":[],"productBrand":null}');
    expect(c.productBrand, isNull);
    expect(c.hasProduct, isFalse);
  });

  test('模型给了空串/占位词也当作没有产品', () {
    for (final raw in ['""', '"无"', '"  "', '"none"', '"未知"']) {
      expect(parseFrameCheck('{"burnedText":[],"productBrand":$raw}').productBrand,
          isNull,
          reason: '「$raw」不是一个品牌');
    }
  });

  test('缺 productBrand 键不算错——烧字那半仍然有效', () {
    final c = parseFrameCheck('{"burnedText":["A"]}');
    expect(c.burnedText, ['A']);
    expect(c.productBrand, isNull);
  });

  test('不是 JSON：必须抛，不许当成「画面干净、没有产品」', () {
    expect(() => parseFrameCheck('画面里没有文字'), throwsFormatException);
  });

  test('缺 burnedText 键：必须抛——那是没答，不是答了「干净」', () {
    expect(() => parseFrameCheck('{"productBrand":"滴露"}'),
        throwsFormatException);
  });

  test('提示词要把两件事都问到，并说清「实物上印的字不算烧字」', () {
    expect(frameCheckPrompt, contains('不算'));
    expect(frameCheckPrompt, contains('productBrand'));
    expect(frameCheckPrompt, contains('burnedText'));
  });

  test('提示词要说清「认不出牌子就给 null」——瞎猜一个牌子比不知道更糟', () {
    expect(frameCheckPrompt, contains('null'));
  });
}
