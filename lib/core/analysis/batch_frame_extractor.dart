import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import 'batch_frame_plan.dart';

/// 一次 ffmpeg 把全片要的帧全抽出来（见 [BatchFramePlan]）。
///
/// **任何对不上都整批作废**，返回 null 让调用方退回逐帧抽。少一张图会让后面
/// 的编号全体前移一位，于是 S7 的标签落到 S6 上——这种错是安静的，用户要到
/// 挑素材时才发现标签牛头不对马嘴，比慢 7 秒严重得多。
class BatchFrameExtractor {
  final ProcessRunner run;
  final String binary;

  BatchFrameExtractor({this.run = systemProcessRunner, this.binary = 'ffmpeg'});

  static const String _prefix = 'batch';

  /// 成功时返回「请求的毫秒 → 图片路径」；任何不确定都返回 null。
  Future<Map<int, String>?> extract({
    required String videoPath,
    required List<int> requestedMs,
    required double fps,
    required Directory outDir,
    required int height,
  }) async {
    final plan = BatchFramePlan.of(requestedMs: requestedMs, fps: fps);
    if (plan.isEmpty) return null;

    await outDir.create(recursive: true);
    final pattern = p.join(outDir.path, '${_prefix}_%03d.jpg');

    final ProcessResult result;
    try {
      result = await run(binary, buildArgs(
        videoPath: videoPath,
        selectExpression: plan.selectExpression,
        height: height,
        outPattern: pattern,
      ));
    } catch (e) {
      AppLog.warn('批量抽帧启动失败，退回逐帧：$e');
      return null;
    }
    if (result.exitCode != 0) {
      AppLog.warn('批量抽帧失败（exit=${result.exitCode}），退回逐帧：${result.stderr}');
      return null;
    }

    final produced = outDir
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('${_prefix}_'))
        .length;
    if (produced != plan.frameNumbers.length) {
      AppLog.warn('批量抽帧只拿到 $produced 张、计划 ${plan.frameNumbers.length} 张，'
          '编号会错位，整批作废退回逐帧');
      return null;
    }

    final byMs = <int, String>{};
    for (final ms in requestedMs) {
      final index = plan.outputIndexOf(ms);
      if (index == null) return null;
      final path = p.join(
          outDir.path, '${_prefix}_${index.toString().padLeft(3, '0')}.jpg');
      if (!File(path).existsSync()) {
        AppLog.warn('批量抽帧少了第 $index 张，整批作废退回逐帧');
        return null;
      }
      byMs[ms] = path;
    }
    return Map.unmodifiable(byMs);
  }

  /// `-vsync 0`：不补帧也不丢帧，吐出的张数必须正好等于 select 命中的帧数，
  /// 否则上面的数量核对就失去意义。
  static List<String> buildArgs({
    required String videoPath,
    required String selectExpression,
    required int height,
    required String outPattern,
  }) =>
      [
        '-y',
        '-loglevel', 'error',
        '-i', videoPath,
        '-vf', "select='$selectExpression',scale=-2:$height",
        '-vsync', '0',
        '-q:v', '3',
        outPattern,
      ];
}
