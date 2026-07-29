import 'dart:io';
import 'dart:typed_data';
import '../ffmpeg/process_runner.dart';

/// 音频 PCM 提取（ffmpeg 子进程封装）：单声道 s16le，供静音检测与 ASR 使用
class AudioExtractor {
  final ProcessRunner run;

  AudioExtractor({this.run = systemProcessRunner});

  static List<String> buildArgs({
    required String videoPath,
    required String outPcmPath,
    int sampleRate = 16000,
  }) =>
      [
        '-loglevel', 'error',
        '-i', videoPath,
        '-vn', '-ac', '1', '-ar', '$sampleRate',
        '-f', 's16le',
        outPcmPath,
        '-y',
      ];

  /// 提取并读取采样；小端序有符号 16 位
  Future<List<int>> extractSamples({
    required String videoPath,
    required String outPcmPath,
    int sampleRate = 16000,
  }) async {
    final result = await run(
        'ffmpeg',
        buildArgs(
            videoPath: videoPath,
            outPcmPath: outPcmPath,
            sampleRate: sampleRate));
    if (result.exitCode != 0) {
      throw FfmpegException(
          'ffmpeg 音频提取失败（exit=${result.exitCode}）：${result.stderr}');
    }
    final bytes = await File(outPcmPath).readAsBytes();
    return bytesToPcm16(bytes);
  }

  static List<int> bytesToPcm16(Uint8List bytes) => bytes.buffer
      .asInt16List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 2)
      .toList();
}
