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

  /// 这个文件能不能解出一段有时长的音频/视频。
  ///
  /// **不要拿 [probe] 当校验器**：它解析的是**视频**信息，遇到纯音频文件会以
  /// 「ffprobe 输出中没有视频流」抛错——真机上正是这样把好好的配乐判成
  /// 「下下来是坏的」，然后删掉重下、再判坏，无限循环。
  Future<bool> playable(String filePath) async {
    try {
      final result = await run('ffprobe', [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=nw=1:nk=1',
        filePath,
      ]);
      if (result.exitCode != 0) return false;
      final seconds = double.tryParse('${result.stdout}'.trim());
      return seconds != null && seconds > 0;
    } catch (_) {
      return false;
    }
  }
}
