import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';

void main() {
  test('buildArgs 生成正确的 PCM 提取参数', () {
    expect(
      AudioExtractor.buildArgs(
          videoPath: '/v/a.mp4', outPcmPath: '/o/a.pcm', sampleRate: 16000),
      [
        '-loglevel', 'error',
        '-i', '/v/a.mp4',
        '-vn', '-ac', '1', '-ar', '16000',
        '-f', 's16le',
        '/o/a.pcm',
        '-y',
      ],
    );
  });

  test('bytesToPcm16 按小端序解析有符号 16 位采样', () {
    final bytes = Uint8List.fromList([0x10, 0x00, 0xF0, 0xFF]);
    expect(AudioExtractor.bytesToPcm16(bytes), [16, -16]);
  });

  test('extractSamples 读取 ffmpeg 产出的 PCM 文件', () async {
    final tempDir = await Directory.systemTemp.createTemp('ishkafel_audio_');
    addTearDown(() => tempDir.delete(recursive: true));
    final pcmPath = '${tempDir.path}/out.pcm';
    final extractor = AudioExtractor(run: (_, args) async {
      // 假 ffmpeg：把 3 个采样 [100, -200, 300] 写入目标文件
      await File(args[args.length - 2]).writeAsBytes(
          Uint8List.fromList([0x64, 0x00, 0x38, 0xFF, 0x2C, 0x01]));
      return ProcessResult(1, 0, '', '');
    });
    final samples = await extractor.extractSamples(
        videoPath: '/v/a.mp4', outPcmPath: pcmPath);
    expect(samples, [100, -200, 300]);
  });

  test('ffmpeg 失败抛 FfmpegException', () async {
    final extractor = AudioExtractor(
        run: (_, _) async => ProcessResult(1, 1, '', 'no audio stream'));
    expect(
      () => extractor.extractSamples(videoPath: '/v/a.mp4', outPcmPath: '/o/a.pcm'),
      throwsA(isA<FfmpegException>()),
    );
  });
}
