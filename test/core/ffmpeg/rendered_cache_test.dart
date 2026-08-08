import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';
import 'package:ishkafel/core/ffmpeg/rendered_cache.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ishkafel_rc_'));
  tearDown(() => temp.deleteSync(recursive: true));

  ({RenderedCache cache, List<List<String>> calls}) make({bool fail = false}) {
    final calls = <List<String>>[];
    return (
      cache: RenderedCache(
        dir: temp,
        run: (binary, args) async {
          calls.add(args);
          if (fail) return ProcessResult(1, 1, '', '炸了');
          await File(args.last).writeAsString('out');
          return ProcessResult(1, 0, '', '');
        },
      ),
      calls: calls,
    );
  }

  Future<String> render(RenderedCache cache, String key) => cache.render(
        key: key,
        prefix: 'clip',
        extension: 'mp4',
        args: (out) => ['-i', 'x', out],
        what: '切一段',
      );

  group('按内容指纹复用', () {
    test('同一个键只跑一次 ffmpeg', () async {
      final env = make();

      final a = await render(env.cache, 'trim|/v/a.mp4|0|1000');
      final b = await render(env.cache, 'trim|/v/a.mp4|0|1000');

      expect(a, b);
      expect(env.calls, hasLength(1));
    });

    test('换了新实例照样命中——认的是磁盘上的文件，不是内存里那张表', () async {
      final first = make();
      await render(first.cache, 'trim|/v/a.mp4|0|1000');

      final second = make();
      await render(second.cache, 'trim|/v/a.mp4|0|1000');

      expect(second.calls, isEmpty,
          reason: '每进一次工作台就新建一个合成器，只认内存表等于永远不命中');
    });

    test('内容变了就是另一个文件——不能按名字复用出上一个方案的内容', () async {
      final env = make();

      final a = await render(env.cache, 'trim|/v/a.mp4|0|1000');
      final b = await render(env.cache, 'trim|/v/a.mp4|0|2000');

      expect(a, isNot(b));
      expect(env.calls, hasLength(2));
    });

    test('不同种类的产物不会撞名', () async {
      final env = make();

      final clip = await env.cache.render(
          key: 'same',
          prefix: 'clip',
          extension: 'mp4',
          args: (out) => [out],
          what: 'a');
      final audio = await env.cache.render(
          key: 'same',
          prefix: 'audio',
          extension: 'wav',
          args: (out) => [out],
          what: 'b');

      expect(clip, isNot(audio));
    });
  });

  group('半截文件不会被当成好的用', () {
    test('先写 .part 再改名，失败时把半截删掉', () async {
      final env = make(fail: true);

      await expectLater(render(env.cache, 'k'), throwsA(isA<FfmpegException>()));

      final left = temp.listSync().map((e) => e.path).toList();
      expect(left, isEmpty, reason: '留下 .part 或 0 字节的成品都会毒害下一次');
    });

    test('临时名把扩展名留在最后——ffmpeg 靠它推断输出格式', () async {
      final env = make();

      await render(env.cache, 'k');

      expect(env.calls.single.last, endsWith('.mp4'),
          reason: '写成 xxx.mp4.part 会让 ffmpeg 报「Unable to choose an '
              'output format」——真机上就这么炸的');
      expect(env.calls.single.last, contains('.part.'));
    });

    test('上次留下的 .part 不算命中', () async {
      final env = make();
      final temp = env.cache
          .tempPathFor(key: 'k', prefix: 'clip', extension: 'mp4');
      File(temp).writeAsStringSync('半截');

      final path = await render(env.cache, 'k');

      expect(env.calls, hasLength(1), reason: '半截文件不能当成已经有了');
      expect(File(path).existsSync(), isTrue);
      expect(File(temp).existsSync(), isFalse, reason: '改名之后半截就没了');
    });

    test('0 字节的成品也不算命中', () async {
      final env = make();
      final path = env.cache
          .pathFor(key: 'k', prefix: 'clip', extension: 'mp4');
      File(path).writeAsStringSync('');

      await render(env.cache, 'k');

      expect(env.calls, hasLength(1));
    });
  });

  group('清理陈旧版本', () {
    test('只留这一轮用到的，其余删掉', () async {
      final env = make();
      final old = await render(env.cache, '上一个方案');
      env.cache.resetTouched();
      final current = await render(env.cache, '这一个方案');

      env.cache.keepOnly();

      expect(File(current).existsSync(), isTrue);
      expect(File(old).existsSync(), isFalse,
          reason: '指纹命名意味着换一次方案就多一套，不清就只增不减');
    });

    test('protect 里的文件一律不动', () async {
      final env = make();
      final state = File('${temp.path}/state.json')..writeAsStringSync('{}');
      await render(env.cache, 'k');

      env.cache.keepOnly(protect: {state.path});

      expect(state.existsSync(), isTrue);
    });

    test('目录不存在时不炸', () {
      final cache = RenderedCache(
          dir: Directory('${temp.path}/nope'),
          run: (_, _) async => ProcessResult(1, 0, '', ''));

      expect(cache.keepOnly, returnsNormally);
    });
  });

  test('同内容同名、异内容不同名', () {
    expect(RenderedCache.digest('a'), RenderedCache.digest('a'));
    expect(RenderedCache.digest('a'), isNot(RenderedCache.digest('b')));
    expect(RenderedCache.digest('a'), hasLength(16));
  });
}
