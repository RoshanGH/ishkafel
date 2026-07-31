import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/media_tools_locator.dart';

void main() {
  group('MediaToolsLocator.resolve', () {
    test('命中 Homebrew 目录（/opt/homebrew/bin）时返回绝对路径', () {
      final locator = MediaToolsLocator(
        probe: (path) => path == '/opt/homebrew/bin/ffmpeg',
        lookupOnPath: (_) => fail('候选目录已命中，不应再查 PATH'),
      );
      expect(locator.resolve('ffmpeg'), '/opt/homebrew/bin/ffmpeg');
    });

    test('Homebrew 目录缺失时回落 /usr/local/bin', () {
      final locator = MediaToolsLocator(
        probe: (path) => path == '/usr/local/bin/ffprobe',
        lookupOnPath: (_) => fail('候选目录已命中，不应再查 PATH'),
      );
      expect(locator.resolve('ffprobe'), '/usr/local/bin/ffprobe');
    });

    test('候选目录都没有时用 PATH 查找结果', () {
      final locator = MediaToolsLocator(
        probe: (_) => false,
        lookupOnPath: (name) => '/somewhere/custom/$name',
      );
      expect(locator.resolve('ffmpeg'), '/somewhere/custom/ffmpeg');
    });

    test('候选目录与 PATH 都找不到时返回 null（不抛异常）', () {
      final locator =
          MediaToolsLocator(probe: (_) => false, lookupOnPath: (_) => null);
      expect(locator.resolve('ffmpeg'), isNull);
    });

    test('解析结果缓存：命中与未命中都只探测一次', () {
      var probeCalls = 0;
      var lookupCalls = 0;
      final hit = MediaToolsLocator(
        probe: (path) {
          probeCalls++;
          return path == '/opt/homebrew/bin/ffmpeg';
        },
        lookupOnPath: (_) => null,
      );
      hit.resolve('ffmpeg');
      hit.resolve('ffmpeg');
      expect(probeCalls, 1, reason: '命中结果应被缓存');

      final miss = MediaToolsLocator(probe: (_) => false, lookupOnPath: (_) {
        lookupCalls++;
        return null;
      });
      miss.resolve('ffmpeg');
      miss.resolve('ffmpeg');
      expect(lookupCalls, 1, reason: '未命中结果同样应被缓存，避免反复探测');
    });

    test('自定义候选目录按给定顺序优先', () {
      final locator = MediaToolsLocator(
        searchDirs: const ['/first/bin', '/opt/homebrew/bin'],
        probe: (path) => path.startsWith('/first/bin') ||
            path.startsWith('/opt/homebrew/bin'),
        lookupOnPath: (_) => null,
      );
      expect(locator.resolve('ffmpeg'), '/first/bin/ffmpeg');
    });
  });

  group('MediaToolsStatus', () {
    test('ffmpeg 与 ffprobe 都解析到时 isReady 为 true 且无缺失项', () {
      final locator = MediaToolsLocator(
        probe: (path) => path.startsWith('/opt/homebrew/bin/'),
        lookupOnPath: (_) => null,
      );
      final status = locator.preflight();
      expect(status.isReady, isTrue);
      expect(status.missingTools, isEmpty);
      expect(status.ffmpegPath, '/opt/homebrew/bin/ffmpeg');
      expect(status.ffprobePath, '/opt/homebrew/bin/ffprobe');
    });

    test('全部缺失时 isReady 为 false，缺失项包含两个工具名', () {
      final locator =
          MediaToolsLocator(probe: (_) => false, lookupOnPath: (_) => null);
      final status = locator.preflight();
      expect(status.isReady, isFalse);
      expect(status.missingTools, ['ffmpeg', 'ffprobe']);
    });

    test('只缺 ffprobe 时 isReady 为 false 且只列出 ffprobe', () {
      final locator = MediaToolsLocator(
        probe: (path) => path == '/usr/local/bin/ffmpeg',
        lookupOnPath: (_) => null,
      );
      final status = locator.preflight();
      expect(status.isReady, isFalse);
      expect(status.missingTools, ['ffprobe']);
    });
  });
}
