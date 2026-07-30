import 'dart:io';
import 'dart:math' as math;

import '../../core/analysis/audio_extractor.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/log/app_log.dart';

/// 时间线辅助素材：等间隔缩略帧序列 + 归一化波形包络
class TimelineMedia {
  final List<String> thumbPaths;
  final List<double> waveEnvelope;

  /// 用不可变列表包裹，避免调用方误改已构建好的产物
  TimelineMedia({required List<String> thumbPaths, required List<double> waveEnvelope})
      : thumbPaths = List.unmodifiable(thumbPaths),
        waveEnvelope = List.unmodifiable(waveEnvelope);
}

/// 时间线媒体构建器：抽取等间隔缩略图 + 计算音频波形包络
///
/// 时间线是辅助视觉，任何一步失败都不应阻断审片台页面：
/// 抽帧失败则跳过该张，音频提取失败则包络返回全 0，均只记录警告日志。
class TimelineMediaBuilder {
  final ThumbnailService thumbnails;
  final AudioExtractor audio;

  TimelineMediaBuilder({required this.thumbnails, required this.audio});

  /// 缩略图缓存最小有效字节数：远小于正常抽帧输出（JPEG 文件头 + 最小编码数据
  /// 通常远超过此值），只用于过滤 0 字节/被中途截断的坏缓存文件
  static const int _minValidThumbBytes = 512;

  /// PCM 缓存最小有效字节数（严格大于此值才算有效）：16 位小端采样至少占 2
  /// 字节，阈值取 1 即要求长度 >= 2，否则视为损坏产物（例如上次运行中途失败
  /// 留下的半截文件，凑不出一个完整采样）
  static const int _minValidPcmBytes = 1;

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
      if (await _isValidCacheFile(outPath, _minValidThumbBytes)) {
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
      final samples = await _isValidCacheFile(pcmPath, _minValidPcmBytes)
          ? AudioExtractor.bytesToPcm16(await File(pcmPath).readAsBytes())
          : await audio.extractSamples(
              videoPath: videoPath, outPcmPath: pcmPath);
      return computeEnvelope(samples, waveBuckets);
    } catch (e) {
      AppLog.warn('时间线音频提取失败（taskId=$taskId）：$e');
      return List.filled(waveBuckets, 0.0);
    }
  }

  /// 缓存文件有效性校验：存在且字节数超过阈值，避免复用 0 字节/被截断的坏产物
  Future<bool> _isValidCacheFile(String path, int minValidBytes) async {
    final file = File(path);
    if (!await file.exists()) return false;
    return await file.length() > minValidBytes;
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
