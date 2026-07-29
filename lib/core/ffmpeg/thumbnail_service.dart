import 'process_runner.dart';

/// 抽帧封面（ffmpeg 子进程封装）
class ThumbnailService {
  final ProcessRunner run;

  ThumbnailService({this.run = systemProcessRunner});

  static List<String> buildArgs({
    required String videoPath,
    required String outPath,
    required double atSeconds,
    required int height,
  }) =>
      [
        '-loglevel', 'error',
        '-ss', '$atSeconds',
        '-i', videoPath,
        '-frames:v', '1',
        '-vf', 'scale=-2:$height',
        '-q:v', '3',
        outPath,
        '-y',
      ];

  Future<String> extractCover({
    required String videoPath,
    required String outPath,
    double atSeconds = 1.0,
    int height = 480,
  }) async {
    final result = await run(
        'ffmpeg',
        buildArgs(
            videoPath: videoPath,
            outPath: outPath,
            atSeconds: atSeconds,
            height: height));
    if (result.exitCode != 0) {
      throw FfmpegException(
          'ffmpeg 抽帧失败（exit=${result.exitCode}）：${result.stderr}');
    }
    return outPath;
  }
}
