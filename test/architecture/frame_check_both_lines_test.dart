import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 画面自查（烧字 + 产品露出品牌）在**两条线上都得有**。
///
/// 替换裂变（工作台）那边刚接全了三条路。脚本成片（编导台）这边一开始
/// 整条缺席——而它**更需要**：
///
/// - 替换裂变至少还有原片作参照，脚本成片是从零造片
/// - 两条线都要给台词烧一行字幕。素材画面上本来就烧着别家的字，
///   叠上去就是两层字、内容还毫不相干——**片子直接废，两条线一样废**
/// - 品牌错位在这边更难发现：没有原片，就没有「本片是什么牌子」的现成参照
///
/// 这是「整条缺席的功能线」的典型——比某个字段漏报隐蔽得多：
/// 替换裂变那边测试全绿、真机验过，看起来这件事已经做完了。
void main() {
  test('脚本成片挑中的素材也要记下画面自查结果', () {
    const shot = LineShot(materialId: 1, name: 'm');
    final json = shot.toJson();
    // 字段存在（值可以是 null = 没查过）
    expect(
      shot.burnedText,
      anyOf(isNull, isA<List<String>>()),
      reason: 'LineShot 没有 burnedText：脚本成片给每句台词烧字幕，'
          '素材上本来有字就是两层——和替换裂变一样废片',
    );
    expect(json, isA<Map<String, dynamic>>());
  });

  test('脚本成片也要记产品露出的品牌', () {
    const shot = LineShot(materialId: 1, name: 'm', productBrand: '滴露');
    expect(shot.productBrand, '滴露');
    expect(LineShot.tryFromJson(shot.toJson())!.productBrand, '滴露',
        reason: '存得下读不回来等于没存');
  });

  test('「没查过」和「画面干净」要分得开', () {
    const unchecked = LineShot(materialId: 1, name: 'm');
    const clean = LineShot(materialId: 1, name: 'm', burnedText: []);
    expect(unchecked.frameChecked, isFalse);
    expect(clean.frameChecked, isTrue);
    expect(clean.hasBurnedText, isFalse);
  });

  test('编导台那条线真的把检查跑起来了，不是只加了字段', () {
    final wiring =
        File('lib/core/script/script_service_wiring.dart').readAsStringSync();
    final apply =
        File('lib/cli/commands/script_apply_command.dart').readAsStringSync();
    expect('$wiring$apply', contains('frameCheck'),
        reason: '字段加了却没人写，就是 pickedMaterials 那次的重演——'
            '模型有、界面在写、Agent 那条路一直空着，白做一轮');
  });
}
