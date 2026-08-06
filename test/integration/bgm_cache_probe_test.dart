// 探针：任务里存的签名地址会过期（真机上隔天就 403），验证缓存能自愈。
//
//   flutter test test/integration/bgm_cache_probe_test.dart --tags integration --run-skipped
@Tags(['integration'])
library;
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_cache.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/miaoa/miaoa_locator.dart';

void main() {
  test('存下来的签名地址失效后，按 id 现取一个新的并落到本地', () async {
    final dir = Directory('${Platform.environment['HOME']}/Library/Application Support/com.jichuang.ishkafel/ishkafel_data/bgm_cache');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    final cache = BgmCache(
      library: BgmLibrary(binary: resolveMiaoaBinary()),
      cacheDir: dir,
    );
    // 任务里存的那个签名地址已经 403
    const stale = BgmMaterial(
      id: 108,
      name: '快乐的尤克里里_C83737177381888',
      durationMs: 122540,
      previewUrl: 'https://cdn-jichuangmeiao-miaoa.mininglamp.com/prod/tenant-19/project-100038/material_audio/20260804/3297bf1c607d46bfbdd418e29594eac7.MP3?sign=1785913966-6098bc062d8245798c741110cb59722c-0-c917c617212c5777bec70a578410c96a',
    );
    final t = DateTime.now();
    final path = await cache.fetch(stale);
    final ms = DateTime.now().difference(t).inMilliseconds;
    // ignore: avoid_print
    print('下到本地：$path  ${File(path).lengthSync()} 字节  ${ms}ms');

    final t2 = DateTime.now();
    await cache.fetch(stale);
    // ignore: avoid_print
    print('第二次（命中缓存）：${DateTime.now().difference(t2).inMilliseconds}ms');
    expect(File(path).lengthSync(), greaterThan(100000));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
