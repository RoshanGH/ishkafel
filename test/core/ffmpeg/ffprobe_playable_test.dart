import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/ffprobe_service.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';

FfprobeService _probe(String stdout, {int exitCode = 0}) => FfprobeService(
      run: (binary, args) async => ProcessResult(1, exitCode, stdout, ''),
    );

void main() {
  group('校验一个文件能不能播', () {
    test('纯音频也算能播——它没有视频流，但那不是「坏文件」', () async {
      expect(await _probe('152.058750\n').playable('/a.mp3'), isTrue,
          reason: '真机上拿 probe（解析视频信息）当校验器，'
              '纯音频以「没有视频流」抛错，好好的配乐被判成坏的、'
              '删掉重下、再判坏，无限循环');
    });

    test('ffprobe 读不出来就是坏的', () async {
      expect(await _probe('', exitCode: 1).playable('/a.mp3'), isFalse);
    });

    test('时长为 0 或读不出数字也算坏的', () async {
      expect(await _probe('0\n').playable('/a.mp3'), isFalse);
      expect(await _probe('N/A\n').playable('/a.mp3'), isFalse);
    });

    test('ffprobe 起不来时不抛，返回「不能播」让调用方兜底', () async {
      final probe = FfprobeService(
          run: (binary, args) async => throw const FfmpegException('没装'));

      expect(await probe.playable('/a.mp3'), isFalse);
    });
  });
}
