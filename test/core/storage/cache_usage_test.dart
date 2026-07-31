import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/cache_usage.dart';

late Directory _root;
late Directory _covers;
late Directory _work;

void _write(Directory dir, String name, int bytes) {
  File('${dir.path}/$name')
    ..createSync(recursive: true)
    ..writeAsBytesSync(List<int>.filled(bytes, 0));
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cache_usage_test');
    _covers = Directory('${_root.path}/covers')..createSync();
    _work = Directory('${_root.path}/analysis_work')..createSync();
  });

  tearDown(() => _root.deleteSync(recursive: true));

  group('容量统计', () {
    test('分目录统计字节数与文件数', () async {
      _write(_covers, 'a.jpg', 100);
      _write(_work, 'a.pcm', 1000);
      _write(_work, 'a_tl32_0.jpg', 500);

      final usage = await CacheScanner(coversDir: _covers, workDir: _work)
          .scan(knownTaskIds: const {'a'});

      expect(usage.coversBytes, 100);
      expect(usage.workBytes, 1500);
      expect(usage.totalBytes, 1600);
      expect(usage.fileCount, 3);
    });

    test('目录不存在时给 0，而不是抛异常', () async {
      final usage = await CacheScanner(
        coversDir: Directory('${_root.path}/nope'),
        workDir: Directory('${_root.path}/nope2'),
      ).scan(knownTaskIds: const {});

      expect(usage.totalBytes, 0);
      expect(usage.fileCount, 0);
    });

    test('子目录里的文件也算进去', () async {
      _write(_work, 'sub/deep.bin', 700);

      final usage = await CacheScanner(coversDir: _covers, workDir: _work)
          .scan(knownTaskIds: const {});

      expect(usage.workBytes, 700,
          reason: '只数第一层会把「已清理干净」的假象报给用户');
    });
  });

  group('孤儿产物识别（任务已删除但产物还在）', () {
    test('归属不到任何现存任务的文件算孤儿', () async {
      _write(_work, 'alive.pcm', 100);
      _write(_work, 'ghost.pcm', 300);
      _write(_covers, 'ghost.jpg', 50);

      final usage = await CacheScanner(coversDir: _covers, workDir: _work)
          .scan(knownTaskIds: const {'alive'});

      expect(usage.orphanBytes, 350);
      expect(usage.orphanCount, 2);
      expect(usage.reclaimableBytes, 350,
          reason: '「可回收」只应包含孤儿；把在用任务的产物算进去，'
              '用户点了清理就会让现有任务失去封面和波形');
    });

    test('id 互为前缀的两个任务不会互相误伤', () async {
      _write(_work, 'ab.pcm', 100);
      _write(_work, 'abc.pcm', 100);

      final usage = await CacheScanner(coversDir: _covers, workDir: _work)
          .scan(knownTaskIds: const {'ab'});

      expect(usage.orphanCount, 1, reason: 'abc 才是孤儿，ab 的产物必须保住');
      expect(usage.orphanBytes, 100);
    });

    test('全部任务都还在时没有可回收空间', () async {
      _write(_work, 'a.pcm', 100);
      _write(_covers, 'a.jpg', 50);

      final usage = await CacheScanner(coversDir: _covers, workDir: _work)
          .scan(knownTaskIds: const {'a'});

      expect(usage.orphanCount, 0);
      expect(usage.reclaimableBytes, 0);
    });
  });

  group('清理孤儿产物', () {
    test('只删孤儿，在用任务的产物原封不动', () async {
      _write(_work, 'alive.pcm', 100);
      _write(_work, 'ghost.pcm', 300);

      final scanner = CacheScanner(coversDir: _covers, workDir: _work);
      final freed = await scanner.purgeOrphans(knownTaskIds: const {'alive'});

      expect(freed, 300);
      expect(File('${_work.path}/alive.pcm').existsSync(), isTrue);
      expect(File('${_work.path}/ghost.pcm').existsSync(), isFalse);
    });

    test('单个文件删不掉（占用/权限）不影响其余文件被清理', () async {
      _write(_work, 'ghost1.pcm', 100);
      _write(_work, 'ghost2.pcm', 200);

      final scanner = CacheScanner(
        coversDir: _covers,
        workDir: _work,
        deleteFile: (file) async {
          if (file.path.endsWith('ghost1.pcm')) throw const FileSystemException('占用中');
          await file.delete();
        },
      );
      final freed = await scanner.purgeOrphans(knownTaskIds: const {});

      expect(freed, 200, reason: '实际释放的只有删成功的那部分，不能虚报');
      expect(File('${_work.path}/ghost2.pcm').existsSync(), isFalse);
    });

    test('没有孤儿时不动任何文件', () async {
      _write(_work, 'a.pcm', 100);

      final freed = await CacheScanner(coversDir: _covers, workDir: _work)
          .purgeOrphans(knownTaskIds: const {'a'});

      expect(freed, 0);
      expect(File('${_work.path}/a.pcm').existsSync(), isTrue);
    });
  });

  group('容量文案', () {
    test('按量级换单位，不给用户看一长串字节数', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(14 * 1024 * 1024), '14.0 MB');
      expect(formatBytes(2 * 1024 * 1024 * 1024), '2.00 GB');
    });

    test('GB 保留两位、MB/KB 保留一位——大数字更需要精度', () {
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1610612736), '1.50 GB');
    });
  });
}
