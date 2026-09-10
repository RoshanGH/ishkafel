import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **不许在没内容的时候假装在播。**
///
/// 2026-09-10 真机走查：编导台「自动铺一版」跑完，无条件 `play()` 了一下。
/// 脚本还没挑镜头时预览轨是空的——播放器进了「正在播」的状态却停在 0，
/// 屏幕上是一个暂停按钮配着 00:00 / 00:00，SnackBar 还说「正在播」。
/// 状态跟事实对不上是这个项目最不能接受的一类问题。
void main() {
  test('铺完开播那一下要先看方案空不空', () {
    final src =
        File('lib/features/director/director_page.dart').readAsStringSync();
    final at = src.indexOf('setState(() => _draftCelebrating = false);');
    expect(at, isNot(-1), reason: '没找到「铺完」那一段，正则该更新了');

    // 从「庆祝收尾」到那一段结束之间，play() 之前必须挡一道
    final tail = src.substring(at, at + 600);
    final guard = tail.indexOf('_planResult.isEmpty');
    // 找真正的调用，别匹配到注释里提到的那个
    final play = tail.indexOf(r'_playback?.play()');

    expect(guard, isNot(-1),
        reason: '铺完无条件开播——预览是空的时候会摆出一个假的「正在播」');
    expect(guard, lessThan(play), reason: '要先判空，再决定播不播');
  });

  test('一句都没进预览时，提示里不许说「正在播」', () {
    final src =
        File('lib/features/director/director_page.dart').readAsStringSync();

    expect(src, contains('现在还没有可播的内容'),
        reason: '空方案要有自己的说法，不能沿用「铺好了，正在播」');
  });
}
