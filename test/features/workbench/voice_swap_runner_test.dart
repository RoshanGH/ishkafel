import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/voice_swap_runner.dart';

late List<(String, List<String>)> calls;

Future<ProcessResult> _fakeRun(String exe, List<String> args) async {
  calls.add((exe, args));
  if (exe == 'ffmpeg') {
    // 造出 ffmpeg 该产出的那个文件，否则切片会被判失败
    await File(args.last).writeAsBytes(List<int>.filled(32, 7));
    return ProcessResult(1, 0, '', '');
  }
  return ProcessResult(1, 0, '2.831000\n', '');
}

void main() {
  setUp(() => calls = []);

  test('切原声走 ffmpeg，输出 16kHz 单声道 WAV', () async {
    final dir = Directory.systemTemp.createTempSync('ishkafel_vsr_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final service = buildVoiceSwapService(
      arkApiKey: 'k',
      speechAppId: 'a',
      speechAccessToken: 't',
      sourcePath: '/v/a.mp4',
      workDir: dir,
      run: _fakeRun,
    );

    final bytes = await service.sliceOriginal(1000, 3000);

    expect(bytes, hasLength(32));
    final args = calls.first.$2;
    expect(calls.first.$1, 'ffmpeg');
    expect(args, containsAllInOrder(['-ar', '16000']));
    expect(args, containsAllInOrder(['-ac', '1']));
    expect(args, containsAllInOrder(['-ss', '1.0', '-to', '3.0']));
    expect(args, contains('-vn'), reason: '只要音频，带上视频流白白解码');
  });

  test('量时长走 ffprobe，秒转毫秒', () async {
    final dir = Directory.systemTemp.createTempSync('ishkafel_vsr_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final service = buildVoiceSwapService(
      arkApiKey: 'k',
      speechAppId: 'a',
      speechAccessToken: 't',
      sourcePath: '/v/a.mp4',
      workDir: dir,
      run: _fakeRun,
    );

    expect(await service.measureMs(const [1, 2, 3]), 2831);
    expect(calls.first.$1, 'ffprobe');
  });

  test('量不出时长时返回 0，让上层跳过对齐而不是拿瞎猜的值去改语速', () async {
    final dir = Directory.systemTemp.createTempSync('ishkafel_vsr_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final service = buildVoiceSwapService(
      arkApiKey: 'k',
      speechAppId: 'a',
      speechAccessToken: 't',
      sourcePath: '/v/a.mp4',
      workDir: dir,
      run: (exe, args) async => ProcessResult(1, 0, 'N/A', ''),
    );

    expect(await service.measureMs(const [1, 2, 3]), 0);
  });

  test('切片失败时抛出而不是返回空音频', () async {
    final dir = Directory.systemTemp.createTempSync('ishkafel_vsr_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final service = buildVoiceSwapService(
      arkApiKey: 'k',
      speechAppId: 'a',
      speechAccessToken: 't',
      sourcePath: '/v/a.mp4',
      workDir: dir,
      run: (exe, args) async => ProcessResult(1, 1, '', 'boom'),
    );

    expect(() => service.sliceOriginal(0, 1000), throwsA(isA<Exception>()),
        reason: '返回空音频会让模型对着一段静音瞎猜演绎方式');
  });
}
