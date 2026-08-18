import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_cache.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:path/path.dart' as p;

const _material = BgmMaterial(
  id: 108,
  name: '快乐的尤克里里',
  durationMs: 122540,
  // 存在任务里的那个签名地址，隔天就 403 了
  previewUrl: 'https://cdn/a.mp3?sign=expired',
);

Directory _temp() {
  final dir = Directory.systemTemp.createTempSync('ishkafel_bgmcache_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

/// 假 miaoa：`content get --type audio <id>` 返回一个新签名地址
BgmLibrary _library({String fresh = 'https://cdn/a.mp3?sign=fresh'}) =>
    BgmLibrary(gateway: MiaoaGateway(run: (binary, args) async => ProcessResult(
          1,
          0,
          '{"id":108,"name":"快乐的尤克里里",'
              '"mediaFile":{"duration":122540,"previewUrl":"$fresh"}}',
          ''), binary: 'miaoa'));

void main() {
  test('第一次用就下到本地，之后不再联网', () async {
    final dir = _temp();
    final asked = <String>[];
    final cache = BgmCache(
      library: _library(),
      cacheDir: dir,
      download: (url, to) async {
        asked.add(url);
        to.writeAsStringSync('mp3');
      },
    );

    final first = await cache.fetch(_material);
    final second = await cache.fetch(_material);

    expect(p.basename(first), '108.mp3');
    expect(second, first);
    expect(asked, hasLength(1),
        reason: '每次调音量都重下一遍 2MB 的曲子，预览会慢得没法用');
  });

  test('下载用的是**新取的**地址，不是任务里存的那个', () async {
    final dir = _temp();
    final asked = <String>[];
    final cache = BgmCache(
      library: _library(),
      cacheDir: dir,
      download: (url, to) async {
        asked.add(url);
        to.writeAsStringSync('mp3');
      },
    );

    await cache.fetch(_material);

    expect(asked.single, 'https://cdn/a.mp3?sign=fresh',
        reason: '签名地址会失效——存进任务里的那个隔天就 403，'
            '真机上正是这样让预览音轨整条合成失败的');
  });

  test('取不到新地址时退回任务里存的那个，不是直接放弃', () async {
    final dir = _temp();
    final asked = <String>[];
    final cache = BgmCache(
      library: BgmLibrary(gateway: MiaoaGateway(run: (binary, args) async => ProcessResult(1, 1, '', 'boom'), binary: 'miaoa')),
      cacheDir: dir,
      download: (url, to) async {
        asked.add(url);
        to.writeAsStringSync('mp3');
      },
    );

    await cache.fetch(_material);

    expect(asked.single, contains('sign=expired'),
        reason: '刚选完就导出时，存着的那个还没过期，能用');
  });

  test('半截文件不留在缓存里——ffmpeg 报的错完全看不懂', () async {
    final dir = _temp();
    final cache = BgmCache(
      library: _library(),
      cacheDir: dir,
      download: (url, to) async {
        to.writeAsStringSync('半截');
        throw const SocketException('断了');
      },
    );

    await expectLater(cache.fetch(_material), throwsA(isA<Exception>()));
    expect(File(p.join(dir.path, '108.mp3')).existsSync(), isFalse);
    expect(File(p.join(dir.path, '108.mp3.part')).existsSync(), isFalse);
  });

  test('上次留下的空文件视为没下完，重下', () async {
    final dir = _temp();
    File(p.join(dir.path, '108.mp3')).writeAsStringSync('');
    var downloads = 0;
    final cache = BgmCache(
      library: _library(),
      cacheDir: dir,
      download: (url, to) async {
        downloads++;
        to.writeAsStringSync('mp3');
      },
    );

    await cache.fetch(_material);

    expect(downloads, 1);
  });

  test('一个可用地址都没有时说人话', () async {
    final dir = _temp();
    final cache = BgmCache(
      library: _library(fresh: ''),
      cacheDir: dir,
      download: (url, to) async => to.writeAsStringSync('mp3'),
    );

    await expectLater(
      cache.fetch(const BgmMaterial(
          id: 7, name: '没地址', durationMs: 1000, previewUrl: null)),
      throwsA(predicate((e) => '$e'.contains('没地址'))),
    );
  });
}
