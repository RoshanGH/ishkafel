import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/vocal_separator.dart';

/// 取参数后面紧跟的那个值
String? valueAfter(List<String> args, String flag) {
  final i = args.indexOf(flag);
  return i < 0 || i + 1 >= args.length ? null : args[i + 1];
}

({VocalSeparator separator, List<List<String>> calls, Directory out})
    _build({
  int exitCode = 0,
  String stderr = '',
  bool produceFiles = true,
}) {
  final calls = <List<String>>[];
  final work = Directory.systemTemp.createTempSync('ishkafel_sep_');
  addTearDown(() => work.deleteSync(recursive: true));
  final out = Directory('${work.path}/stems');

  return (
    separator: VocalSeparator(
      modelDir: Directory('${work.path}/models'),
      run: (bin, args) async {
        calls.add(args);
        if (exitCode == 0 && produceFiles) {
          out.createSync(recursive: true);
          File('${out.path}/a-人声.wav').writeAsStringSync('v');
          File('${out.path}/a-背景.wav').writeAsStringSync('b');
        }
        return ProcessResult(1, exitCode, '', stderr);
      },
    ),
    calls: calls,
    out: out,
  );
}

void main() {
  test('分离出人声与背景两条轨', () async {
    final b = _build();

    final stems =
        await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    expect(stems.vocalsPath, endsWith('a-人声.wav'));
    expect(stems.backgroundPath, endsWith('a-背景.wav'));
  });

  test('用实测最快的那套参数——默认参数要 2 分 09 秒，这套只要 15 秒', () async {
    final b = _build();

    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    final args = b.calls.single;
    expect(valueAfter(args, '--mdx_batch_size'), '8');
    expect(valueAfter(args, '--mdx_segment_size'), '512');
    expect(valueAfter(args, '--model_filename'), VocalSeparator.model);
  });

  test('模型目录必须显式指定：工具默认放 /tmp，系统一清就要重下几百兆',
      () async {
    final b = _build();

    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    final dir = valueAfter(b.calls.single, '--model_file_dir');
    expect(dir, isNotNull);
    expect(dir, isNot(startsWith('/tmp/audio-separator')));
    expect(Directory(dir!).existsSync(), isTrue, reason: '目录要先建好');
  });

  test('输出文件名固定，不去猜工具按模型名拼出来的那一长串', () async {
    final b = _build();

    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    expect(valueAfter(b.calls.single, '--custom_output_names'),
        contains('a-人声'));
  });

  test('已经分离过就直接复用，不再跑一遍十几秒', () async {
    final b = _build();

    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);
    await b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out);

    expect(b.calls, hasLength(1));
  });

  test('工具没装时给的是「请先安装」，不是一句看不懂的报错', () async {
    final b = _build(exitCode: 127, stderr: 'command not found');

    expect(
      () => b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out),
      throwsA(isA<VocalSeparationException>().having(
          (e) => e.message, 'message', contains('未检测到人声分离工具'))),
    );
  });

  test('跑成功了却没产出文件，同样要报错而不是给一个不存在的路径', () async {
    final b = _build(produceFiles: false);

    expect(
      () => b.separator.separate(audioPath: '/tmp/a.wav', outputDir: b.out),
      throwsA(isA<VocalSeparationException>()),
    );
  });
}
