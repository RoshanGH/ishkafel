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
    previewUrl: 'https://cdn/a.mp3?sign=expired');

Directory _temp() {
  final dir = Directory.systemTemp.createTempSync('ishkafel_reval_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

BgmLibrary _library() => BgmLibrary(gateway: MiaoaGateway(run: (binary, args) async => ProcessResult(
          1,
          0,
          '{"id":108,"mediaFile":{"previewUrl":"https://cdn/a.mp3?sign=fresh"}}',
          ''), binary: 'miaoa'));

void main() {
  test('缓存里躺着一个坏文件时，删掉重下', () async {
    final dir = _temp();
    // 上一次下崩了，留下一个解不出来的文件
    File(p.join(dir.path, '108.mp3')).writeAsStringSync('不是音频');
    final asked = <String>[];

    final cache = BgmCache(
      library: _library(),
      cacheDir: dir,
      download: (url, to) async {
        asked.add(url);
        to.writeAsStringSync('好的音频');
      },
      // ffprobe 读不出来就是坏的
      verify: (path) async => File(path).readAsStringSync() != '不是音频',
    );

    final path = await cache.fetch(_material);

    expect(asked, hasLength(1), reason: '坏文件必须重下，否则导出时才发现');
    expect(File(path).readAsStringSync(), '好的音频');
  });

  test('缓存是好的就不重下，也不去验第二遍', () async {
    final dir = _temp();
    File(p.join(dir.path, '108.mp3')).writeAsStringSync('好的音频');
    final asked = <String>[];
    var verified = 0;

    final cache = BgmCache(
      library: _library(),
      cacheDir: dir,
      download: (url, to) async => asked.add(url),
      verify: (path) async {
        verified++;
        return true;
      },
    );

    await cache.fetch(_material);
    await cache.fetch(_material);

    expect(asked, isEmpty);
    expect(verified, 1, reason: '同一次会话里验一遍就够，每次都 ffprobe 是浪费');
  });

  test('重下之后还是坏的就报错，不把坏文件交出去', () async {
    final dir = _temp();
    File(p.join(dir.path, '108.mp3')).writeAsStringSync('不是音频');

    final cache = BgmCache(
      library: _library(),
      cacheDir: dir,
      download: (url, to) async => to.writeAsStringSync('还是坏的'),
      verify: (path) async => false,
    );

    await expectLater(
      cache.fetch(_material),
      throwsA(isA<BgmUnavailableException>()),
    );
  });

  test('不注入校验器时按老行为走——有文件就用', () async {
    final dir = _temp();
    File(p.join(dir.path, '108.mp3')).writeAsStringSync('随便什么');
    final asked = <String>[];

    final cache = BgmCache(
      library: _library(),
      cacheDir: dir,
      download: (url, to) async => asked.add(url),
    );

    await cache.fetch(_material);

    expect(asked, isEmpty);
  });
}
