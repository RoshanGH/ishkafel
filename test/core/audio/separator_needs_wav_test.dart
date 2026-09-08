import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/vocal_separator.dart';

/// **喂给分离工具的必须是它读得懂的音频，不能直接甩一个 mp4 过去。**
///
/// 真机 bug（2026-09-07）：这台机器上分离**从来没成功过**——`separator_models`
/// 一直是空的。手跑一次才看到真相：
///
/// ```
/// soundfile.LibsndfileError: Error opening '…/114799.mp4': Format not recognised.
/// ```
///
/// `audio-separator` 走 `soundfile` 读输入，它认 wav/flac 这类，不认 mp4。
/// 而 app 一直把视频文件原样喂过去（原片和素材都是）。先用 ffmpeg 抽一道
/// 音频再喂，实测 4 秒分完。
///
/// 这个错误藏得深：界面只说「分离失败」，日志里那句 `Format not recognised`
/// 不跑一次真机根本看不到。
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('sep_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('输入是视频时，先抽音频再交给分离工具', () async {
    final video = File('${tmp.path}/a.mp4')..writeAsBytesSync([0]);
    final calls = <List<String>>[];
    String? extractedFrom;

    final separator = VocalSeparator(
      modelDir: Directory('${tmp.path}/models'),
      run: (bin, args) async {
        calls.add(args);
        // 产物按约定名落盘，让 separate 认为成功
        for (final name in ['人声', '背景']) {
          File('${tmp.path}/out/${_stem(args)}-$name.wav')
            ..createSync(recursive: true)
            ..writeAsBytesSync([1, 2, 3]);
        }
        return ProcessResult(1, 0, '', '');
      },
      extractAudio: (input, out) async {
        extractedFrom = input;
        File(out).writeAsBytesSync([1]);
        return out;
      },
    );

    await separator.separate(
        audioPath: video.path, outputDir: Directory('${tmp.path}/out'));

    expect(extractedFrom, video.path, reason: '视频要先过一道 ffmpeg');
    expect(calls.single.first, isNot(endsWith('.mp4')),
        reason: 'soundfile 读不了 mp4——直接喂过去就是 Format not recognised');
    expect(calls.single.first, endsWith('.wav'));
  });

  test('输入本来就是 wav 就不白抽一道', () async {
    final wav = File('${tmp.path}/a.wav')..writeAsBytesSync([0]);
    var extracted = false;

    final separator = VocalSeparator(
      modelDir: Directory('${tmp.path}/models'),
      run: (bin, args) async {
        for (final name in ['人声', '背景']) {
          File('${tmp.path}/out/${_stem(args)}-$name.wav')
            ..createSync(recursive: true)
            ..writeAsBytesSync([1, 2, 3]);
        }
        return ProcessResult(1, 0, '', '');
      },
      extractAudio: (input, out) async {
        extracted = true;
        return out;
      },
    );

    await separator.separate(
        audioPath: wav.path, outputDir: Directory('${tmp.path}/out'));

    expect(extracted, isFalse, reason: '已经是它读得懂的格式，再转一道只是白花时间');
  });
}

/// 从命令行参数里把 `--custom_output_names` 里的 stem 抠出来
String _stem(List<String> args) {
  final json = args[args.indexOf('--custom_output_names') + 1];
  final m = RegExp(r'"Vocals": "(.+?)-人声"').firstMatch(json);
  return m!.group(1)!;
}
