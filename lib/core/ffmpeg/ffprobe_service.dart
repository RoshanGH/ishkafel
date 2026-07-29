import 'dart:convert';
import '../models/video_info.dart';
import 'process_runner.dart';

/// 视频元信息探测（ffprobe 子进程封装）
class FfprobeService {
  final ProcessRunner run;

  FfprobeService({this.run = systemProcessRunner});

  static List<String> buildArgs(String filePath) => [
        '-v', 'error',
        '-show_streams', '-show_format',
        '-print_format', 'json',
        filePath,
      ];

  Future<VideoInfo> probe(String filePath) async {
    final result = await run('ffprobe', buildArgs(filePath));
    if (result.exitCode != 0) {
      throw FfmpegException(
          'ffprobe 失败（exit=${result.exitCode}）：${result.stderr}');
    }
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    return VideoInfo.fromFfprobeJson(json);
  }
}
