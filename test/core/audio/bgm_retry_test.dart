import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_cache.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';

const _material = BgmMaterial(
    id: 108, name: '快乐的尤克里里', durationMs: 122540, previewUrl: 'https://cdn/a.mp3');

Directory _temp() {
  final dir = Directory.systemTemp.createTempSync('ishkafel_retry_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

BgmLibrary _library({String fresh = 'https://cdn/a.mp3?sign=fresh'}) =>
    BgmLibrary(gateway: MiaoaGateway(run: (binary, args) async => ProcessResult(1, 0,
          '{"id":108,"mediaFile":{"previewUrl":"$fresh"}}', ''), binary: 'miaoa'));

/// 素材已从素材库删除：现取地址拿不到，任务里存的那个也 404
BgmLibrary _deleted() => BgmLibrary(gateway: MiaoaGateway(run: (binary, args) async => ProcessResult(1, 0, '{"id":108}', ''), binary: 'miaoa'));

void main() {
  group('网络抖一下不该让人重选配乐', () {
    test('下载失败会自己再试，第二次成了就当没事发生', () async {
      final dir = _temp();
      var attempts = 0;
      final cache = BgmCache(
        library: _library(),
        cacheDir: dir,
        download: (url, to) async {
          attempts++;
          if (attempts == 1) throw const SocketException('网络抖了一下');
          to.writeAsStringSync('好的音频');
        },
        retryDelay: Duration.zero,
      );

      final path = await cache.fetch(_material);

      expect(attempts, 2);
      expect(File(path).readAsStringSync(), '好的音频');
    });

    test('试满次数还是不行才报错，且说得出是网络问题', () async {
      final dir = _temp();
      var attempts = 0;
      final cache = BgmCache(
        library: _library(),
        cacheDir: dir,
        download: (url, to) async {
          attempts++;
          throw const SocketException('断了');
        },
        retryDelay: Duration.zero,
      );

      await expectLater(
        cache.fetch(_material),
        throwsA(isA<BgmUnavailableException>()
            .having((e) => e.retryable, 'retryable', isTrue)
            .having((e) => e.message, 'message', contains('网络'))),
      );
      expect(attempts, greaterThan(1));
    });

    test('素材已删除是永久错误，不浪费时间重试', () async {
      final dir = _temp();
      var attempts = 0;
      final cache = BgmCache(
        library: _deleted(),
        cacheDir: dir,
        download: (url, to) async => attempts++,
        retryDelay: Duration.zero,
      );

      await expectLater(
        cache.fetch(const BgmMaterial(
            id: 7, name: '已删除的', durationMs: 1000, previewUrl: null)),
        throwsA(isA<BgmUnavailableException>()
            .having((e) => e.retryable, 'retryable', isFalse)),
      );
      expect(attempts, 0, reason: '地址都拿不到，重试多少次都一样');
    });
  });

  group('说人话，别把两层错误套在一起', () {
    test('报错里曲名只出现一次', () async {
      final dir = _temp();
      final cache = BgmCache(
        library: _library(),
        cacheDir: dir,
        download: (url, to) async => to.writeAsStringSync('不是音频'),
        verify: (path) async => false,
        retryDelay: Duration.zero,
      );

      try {
        await cache.fetch(_material);
        fail('应该抛错');
      } on BgmUnavailableException catch (e) {
        expect('快乐的尤克里里'.allMatches(e.message).length, 1,
            reason: '真机上这句话套了两层，曲名出现两次，长得没法读');
      }
    });

    test('文件坏了也算可重试——多半是地址失效后返回的错误页', () async {
      final dir = _temp();
      final cache = BgmCache(
        library: _library(),
        cacheDir: dir,
        download: (url, to) async => to.writeAsStringSync('不是音频'),
        verify: (path) async => false,
        retryDelay: Duration.zero,
      );

      await expectLater(
        cache.fetch(_material),
        throwsA(isA<BgmUnavailableException>()
            .having((e) => e.retryable, 'retryable', isTrue)),
      );
    });
  });
}
