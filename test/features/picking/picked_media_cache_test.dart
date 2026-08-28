import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/picking/picked_media_cache.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ishkafel_pmc_'));
  tearDown(() => temp.deleteSync(recursive: true));

  PickedMediaCache make({
    required Future<String> Function(int) fetch,
    int concurrency = 2,
    int quotaBytes = 1 << 30,
  }) =>
      PickedMediaCache(
          fetch: fetch,
          cacheDir: temp,
          concurrency: concurrency,
          quotaBytes: quotaBytes);

  group('勾选即固定在本地', () {
    test('勾上就去下，下完标为已就绪', () async {
      final asked = <int>[];
      final cache = make(fetch: (id) async {
        asked.add(id);
        return '${temp.path}/$id.mp4';
      });

      cache.pin(71);
      expect(cache.statusOf(71), PickedMediaStatus.downloading);
      await Future<void>.delayed(Duration.zero);

      expect(asked, [71]);
      expect(cache.statusOf(71), PickedMediaStatus.ready);
      cache.dispose();
    });

    test('同一条不重复下——它可能被好几个单元选中', () async {
      final asked = <int>[];
      final cache = make(fetch: (id) async {
        asked.add(id);
        return '${temp.path}/$id.mp4';
      });

      cache.pin(71);
      await Future<void>.delayed(Duration.zero);
      cache.pin(71);
      await Future<void>.delayed(Duration.zero);

      expect(asked, [71]);
      cache.dispose();
    });

    test('并发有上限：素材是几十兆的视频，开太多只会互相抢带宽', () async {
      var inflight = 0;
      var peak = 0;
      final gate = Completer<void>();
      final cache = make(
        concurrency: 2,
        fetch: (id) async {
          inflight++;
          peak = peak > inflight ? peak : inflight;
          await gate.future;
          inflight--;
          return '${temp.path}/$id.mp4';
        },
      );

      for (final id in [1, 2, 3, 4, 5]) {
        cache.pin(id);
      }
      await Future<void>.delayed(Duration.zero);
      expect(peak, 2);

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      cache.dispose();
    });

    test('下失败时状态是「失败」，并给一句能照做的原因', () async {
      final cache = make(
          fetch: (_) async => throw Exception('素材 71 没有可用的下载地址，可能已被删除'));

      cache.pin(71);
      await Future<void>.delayed(Duration.zero);

      expect(cache.statusOf(71), PickedMediaStatus.failed);
      expect(cache.failureOf(71), contains('找不到这条素材'));
      cache.dispose();
    });

    test('重试会重新去下', () async {
      var attempts = 0;
      final cache = make(fetch: (id) async {
        attempts++;
        if (attempts == 1) throw Exception('SocketException');
        return '${temp.path}/$id.mp4';
      });

      cache.pin(71);
      await Future<void>.delayed(Duration.zero);
      expect(cache.statusOf(71), PickedMediaStatus.failed);

      cache.retry(71);
      await Future<void>.delayed(Duration.zero);
      expect(cache.statusOf(71), PickedMediaStatus.ready);
      cache.dispose();
    });
  });

  group('取消勾选只解除固定，不删文件', () {
    test('取消之后文件还在——取消常是试错动作，改回来不该重下几十兆', () async {
      final file = File('${temp.path}/71.mp4')..writeAsStringSync('mp4');
      final cache = make(fetch: (id) async => file.path);

      cache.pin(71);
      await Future<void>.delayed(Duration.zero);
      cache.unpin(71);

      expect(file.existsSync(), isTrue);
      expect(cache.pinned, isEmpty);
      cache.dispose();
    });

    test('pinAll 把固定集合整体对齐：多的解除、少的排队', () async {
      final cache = make(fetch: (id) async => '${temp.path}/$id.mp4');

      cache.pinAll({1, 2});
      await Future<void>.delayed(Duration.zero);
      cache.pinAll({2, 3});
      await Future<void>.delayed(Duration.zero);

      expect(cache.pinned, {2, 3});
      cache.dispose();
    });
  });

  group('配额回收', () {
    test('超上限时淘汰未固定的，固定住的一律不动', () async {
      File('${temp.path}/1.mp4').writeAsBytesSync(List.filled(600, 0));
      File('${temp.path}/2.mp4').writeAsBytesSync(List.filled(600, 0));
      final cache = make(
          quotaBytes: 700, fetch: (id) async => '${temp.path}/$id.mp4');

      cache.pin(1);
      await Future<void>.delayed(Duration.zero);
      cache.sweep();

      expect(File('${temp.path}/1.mp4').existsSync(), isTrue,
          reason: '固定住的是用户方案里正在用的素材');
      expect(File('${temp.path}/2.mp4').existsSync(), isFalse);
      cache.dispose();
    });

    test('没超上限就一个都不删', () async {
      File('${temp.path}/2.mp4').writeAsBytesSync(List.filled(100, 0));
      final cache = make(
          quotaBytes: 1000, fetch: (id) async => '${temp.path}/$id.mp4');

      expect(cache.sweep(), 0);
      expect(File('${temp.path}/2.mp4').existsSync(), isTrue);
      cache.dispose();
    });
  });

  group('导出前的拦截依据', () {
    test('还没就绪的固定素材要报出来——素材没齐就导，成片会缺画面', () async {
      final gate = Completer<void>();
      final cache = make(fetch: (id) async {
        await gate.future;
        return '${temp.path}/$id.mp4';
      });

      cache.pin(71);
      await Future<void>.delayed(Duration.zero);
      expect(cache.notReady, [71]);

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(cache.notReady, isEmpty);
      cache.dispose();
    });
  });

  /// 真机上用户问的：「我记得第一次已经下载过了，为什么每次打开都要再下载
  /// 一次？」——文件确实没重下（下载器会跳过已存在的），但每次开任务都把
  /// 一百多条重新排一遍队列，底部横幅于是闪出「正在把 91 条已选素材存到本地」，
  /// 数字慢慢往下掉。人看到的就是「又在下一遍」。
  group('上次已经存到本地的，重开也该认得', () {
    test('本地有文件就直接算就绪，不排队也不去下', () async {
      File('${temp.path}/71.mp4').writeAsStringSync('已经下过的内容');
      final asked = <int>[];
      final cache = make(fetch: (id) async {
        asked.add(id);
        return '${temp.path}/$id.mp4';
      });

      cache.pin(71);

      expect(cache.statusOf(71), PickedMediaStatus.ready);
      expect(asked, isEmpty, reason: '文件就在本地，不该再走一趟下载');
      expect(cache.notReady, isEmpty);
    });

    test('空文件不算——那是上次没下完的半截', () async {
      File('${temp.path}/71.mp4').writeAsStringSync('');
      final asked = <int>[];
      final cache = make(fetch: (id) async {
        asked.add(id);
        return '${temp.path}/$id.mp4';
      });

      cache.pin(71);
      await Future<void>.delayed(Duration.zero);

      expect(asked, [71]);
    });

    test('整批对齐时也认得——重开任务走的就是这条路', () async {
      for (final id in [1, 2, 3]) {
        File('${temp.path}/$id.mp4').writeAsStringSync('x');
      }
      final asked = <int>[];
      final cache = make(fetch: (id) async {
        asked.add(id);
        return '${temp.path}/$id.mp4';
      });

      cache.pinAll({1, 2, 3});
      await Future<void>.delayed(Duration.zero);

      expect(asked, isEmpty);
      expect(cache.notReady, isEmpty,
          reason: '三条都在本地，底部不该再闪「正在存到本地」');
    });
  });

}
