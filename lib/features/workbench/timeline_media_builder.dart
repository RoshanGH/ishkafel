import 'dart:io';
import 'dart:math' as math;

import '../../core/analysis/audio_extractor.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/log/app_log.dart';

/// 时间线辅助素材：等间隔缩略帧序列 + 归一化波形包络
class TimelineMedia {
  final List<String> thumbPaths;
  final List<double> waveEnvelope;

  const TimelineMedia({required this.thumbPaths, required this.waveEnvelope});
}

/// 时间线媒体构建器：抽取等间隔缩略图 + 计算音频波形包络
///
/// 时间线是辅助视觉，任何一步失败都不应阻断审片台页面：
/// 抽帧失败则跳过该张，音频提取失败则包络返回全 0，均只记录警告日志。
class TimelineMediaBuilder {
  final ThumbnailService thumbnails;
  final AudioExtractor audio;

  TimelineMediaBuilder({required this.thumbnails, required this.audio});

  Future<TimelineMedia> build({
    required String videoPath,
    required String taskId,
    required int durationMs,
    required Directory workDir,
    int thumbCount = 14,
    int waveBuckets = 240,
  }) async {
    final thumbPaths = await _buildThumbnails(
      videoPath: videoPath,
      taskId: taskId,
      durationMs: durationMs,
      workDir: workDir,
      thumbCount: thumbCount,
    );
    final waveEnvelope = await _buildEnvelope(
      videoPath: videoPath,
      taskId: taskId,
      workDir: workDir,
      waveBuckets: waveBuckets,
    );
    return TimelineMedia(thumbPaths: thumbPaths, waveEnvelope: waveEnvelope);
  }

  Future<List<String>> _buildThumbnails({
    required String videoPath,
    required String taskId,
    required int durationMs,
    required Directory workDir,
    required int thumbCount,
  }) async {
    final thumbPaths = <String>[];
    for (var i = 0; i < thumbCount; i++) {
      final outPath = '${workDir.path}/${taskId}_tl_$i.jpg';
      if (await File(outPath).exists()) {
        thumbPaths.add(outPath);
        continue;
      }
      final atSeconds = durationMs * (i + 0.5) / thumbCount / 1000.0;
      try {
        final path = await thumbnails.extractCover(
          videoPath: videoPath,
          outPath: outPath,
          atSeconds: atSeconds,
        );
        thumbPaths.add(path);
      } catch (e) {
        AppLog.warn('时间线抽帧失败（第 $i 张，taskId=$taskId）：$e');
      }
    }
    return thumbPaths;
  }

  Future<List<double>> _buildEnvelope({
    required String videoPath,
    required String taskId,
    required Directory workDir,
    required int waveBuckets,
  }) async {
    final pcmPath = '${workDir.path}/${taskId}_tl.pcm';
    try {
      final pcmFile = File(pcmPath);
      final samples = await pcmFile.exists()
          ? AudioExtractor.bytesToPcm16(await pcmFile.readAsBytes())
          : await audio.extractSamples(
              videoPath: videoPath, outPcmPath: pcmPath);
      return computeEnvelope(samples, waveBuckets);
    } catch (e) {
      AppLog.warn('时间线音频提取失败（taskId=$taskId）：$e');
      return List.filled(waveBuckets, 0.0);
    }
  }

  /// 纯函数：PCM 采样均分为 buckets 份，逐份计算 RMS，再按全局最大值归一化到 [0,1]
  ///
  /// 全静音（最大值为 0）或采样为空时返回全 0（长度仍为 buckets）
  static List<double> computeEnvelope(List<int> samples, int buckets) {
    if (buckets <= 0) return const [];
    if (samples.isEmpty) return List.filled(buckets, 0.0);

    final rms = List<double>.filled(buckets, 0.0);
    for (var b = 0; b < buckets; b++) {
      final start = (samples.length * b / buckets).floor();
      final end = (samples.length * (b + 1) / buckets).floor();
      if (end <= start) continue;
      var sumSquares = 0.0;
      for (var i = start; i < end; i++) {
        final value = samples[i].toDouble();
        sumSquares += value * value;
      }
      rms[b] = math.sqrt(sumSquares / (end - start));
    }

    final maxValue = rms.reduce(math.max);
    if (maxValue == 0) return List.filled(buckets, 0.0);
    return rms.map((v) => v / maxValue).toList();
  }
}
