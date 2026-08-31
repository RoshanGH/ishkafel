import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/picking/picked_media_cache.dart';

/// 素材下载要**并行**。
///
/// 它们之间没有任何依赖——几兆的小片子，一条脚本几十条。两条两条地下，
/// 人刚铺完片想点开看一眼，得到的是「素材还没下载好」。
/// 用户的原话：「这个下载应该很快，不冲突，可以同时进行。」
void main() {
  test('默认同时下好几条，不是两条', () async {
    final dir = Directory.systemTemp.createTempSync('mc');
    addTearDown(() => dir.deleteSync(recursive: true));
    var peak = 0;
    var running = 0;
    final cache = PickedMediaCache(
      cacheDir: dir,
      fetch: (id) async {
        running++;
        peak = running > peak ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        running--;
        final f = File('${dir.path}/$id.mp4')..writeAsBytesSync([1, 2, 3]);
        return f.path;
      },
    );
    cache.pinAll({for (var i = 1; i <= 12; i++) i});
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(peak, greaterThan(2),
        reason: '一次只下两条的话，几十条素材要等很久——'
            '而它们之间根本没有先后关系');
    cache.dispose();
  });
}
