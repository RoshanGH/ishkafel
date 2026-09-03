import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **打包 ≠ 上线。**
///
/// 打包是出产物，随时可以做；上线是把这一版推到线上，所有人下次打开就会
/// 被提示更新——那是对外的动作，收不回来，要人点头才做。
///
/// 这条规矩是产品负责人定的：「不是每一次改完以后都直接发版的，版本号可以
/// 接着往后走，但不是每一个版本号都要上线。上线这步需要我人工确认。」
void main() {
  test('打包脚本不许自己上线', () {
    final pack = File('scripts/pack.sh').readAsStringSync();
    expect(pack.contains('dart run tool/publish_release.dart'), isFalse,
        reason: '每改一行就自动往所有人机器上推一版，这是越界');
    expect(pack, contains('还没上线'),
        reason: '打完包要说清「还没上线」，以及要上线该跑什么');
  });

  test('上线脚本要先问一遍', () {
    final publish = File('scripts/publish.sh').readAsStringSync();
    expect(publish, contains('确认上线'));
    expect(publish, contains('CHANGELOG'),
        reason: '问之前要把这一版改了什么摆出来——不能让人盲签');
    expect(publish, contains('--yes'),
        reason: '留一个不问的口子给脚本调用，但那要显式给');
  });

  test('术语表里有这两个词——全项目话术以它为准', () {
    final glossary = File('docs/术语表.md').readAsStringSync();
    expect(glossary, contains('**打包**'));
    expect(glossary, contains('**上线**'));
  });
}
