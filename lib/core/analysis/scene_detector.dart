import '../ffmpeg/process_runner.dart';

/// 视觉场景切换检测（ffmpeg select+showinfo 封装）
///
/// showinfo 的帧信息打在 stderr；每个通过 select 的帧即一个场景切换点。
class SceneDetector {
  final ProcessRunner run;
  final double threshold;

  SceneDetector({this.run = systemProcessRunner, this.threshold = 0.35});

  static List<String> buildArgs({
    required String videoPath,
    required double threshold,
  }) =>
      [
        '-i', videoPath,
        '-vf', "select='gt(scene,$threshold)',showinfo",
        '-f', 'null', '-',
      ];

  static final _ptsTime = RegExp(r'pts_time:([0-9]+(?:\.[0-9]+)?)');

  static List<int> parseBoundaryMs(String showinfoStderr) => [
        for (final m in _ptsTime.allMatches(showinfoStderr))
          (double.parse(m.group(1)!) * 1000).round(),
      ];

  Future<List<int>> detect(String videoPath) async {
    final result = await run(
        'ffmpeg', buildArgs(videoPath: videoPath, threshold: threshold));
    if (result.exitCode != 0) {
      throw FfmpegException(
          'ffmpeg 场景检测失败（exit=${result.exitCode}）：${result.stderr}');
    }
    return parseBoundaryMs(result.stderr as String);
  }
}
