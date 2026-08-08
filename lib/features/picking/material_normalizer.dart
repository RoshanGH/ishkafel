import 'dart:io';

import '../../core/ffmpeg/media_spec.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/rendered_cache.dart';
import '../../core/log/app_log.dart';

/// 把落到本地的候选素材**规格化成和原片一致**。
///
/// **为什么必须做**（真机实测，见 [MediaSpec] 的说明）：原片是 HEVC Main 10、
/// 素材库给的候选是 HEVC Main，就这一处不同，播放器在替换点必须重建解码器
/// ——画面停约 100ms 再跳过去，用户感知为「替换点有顿挫感」。规格对齐之后
/// 那一拍停滞就没了。
///
/// **什么时候做**：素材下载完成之后顺手转一次（本来就在等下载）。一条 11 秒
/// 的素材实测 2.4 秒转完，按内容指纹缓存，换回上一个候选是秒开。
///
/// **不是白转**：导出本来就要把各段统一成同一规格才能拼，这一步的产物导出
/// 直接复用——等于把导出必须做的活提前做了。
///
/// 规格本来就一致的素材**一个字节都不动**，直接返回原路径。
class MaterialNormalizer {
  final RenderedCache cache;
  final ProcessRunner run;

  /// 目标规格：原片长什么样。为 null 表示读不出来——那就不转，
  /// 宁可留着那一下顿挫，也不能拿一个瞎猜的规格去转
  final Future<MediaSpec?> Function() targetSpec;

  MaterialNormalizer({
    required this.cache,
    required this.run,
    required this.targetSpec,
  });

  MediaSpec? _target;
  bool _targetResolved = false;

  /// 返回可直接播的本地路径：规格一致就是 [path] 本身，否则是转好的那一份。
  ///
  /// 转不动就退回原文件——顿挫总比播不了强，但要留下告警。
  Future<String> normalize(String path) async {
    final target = await _resolveTarget();
    if (target == null) return path;
    final spec = await _probe(path);
    if (spec == null || spec.sameAs(target)) return path;

    AppLog.info('素材规格与原片不一致（$spec ≠ $target），规格化一次');
    try {
      return await cache.render(
        key: 'norm|$path|$target',
        prefix: 'norm',
        extension: 'mp4',
        args: (out) => encodeArgs(input: path, target: target, out: out),
        what: '把素材规格对齐原片',
      );
    } catch (e) {
      AppLog.warn('素材规格化失败，先按原样用（替换点可能有一下顿挫）：$e');
      return path;
    }
  }

  /// 转码参数。用 videotoolbox 硬编——实测 11 秒素材 2.4 秒转完；
  /// 软编（libx265）质量更好但要几十秒，预览等不起。
  ///
  /// **只动画面**：声音原样拷贝，一来快，二来重编会损一道音质，而替换点的
  /// 顿挫和音频规格无关。
  static List<String> encodeArgs({
    required String input,
    required MediaSpec target,
    required String out,
  }) =>
      [
        '-y',
        '-i', input,
        '-c:v', _encoderFor(target.codec),
        if (target.profile.isNotEmpty) ...['-profile:v', _profileArg(target.profile)],
        '-pix_fmt', _pixFmtFor(target.pixelFormat),
        '-vf', 'scale=${target.width}:${target.height}',
        '-r', target.frameRate,
        // 码率给足：预览要看清画面，这一份导出也会复用
        '-b:v', '8M',
        // hvc1 标签：不打的话 macOS 的部分环节认不出这是 HEVC
        if (target.codec == 'hevc') ...['-tag:v', 'hvc1'],
        '-c:a', 'copy',
        out,
      ];

  static String _encoderFor(String codec) => switch (codec) {
        'hevc' => 'hevc_videotoolbox',
        'h264' => 'h264_videotoolbox',
        _ => 'hevc_videotoolbox',
      };

  /// ffprobe 报的是 `Main 10`，ffmpeg 要的是 `main10`
  static String _profileArg(String profile) =>
      profile.toLowerCase().replaceAll(' ', '');

  /// videotoolbox 的 10bit 像素格式叫 p010le，不是 yuv420p10le
  static String _pixFmtFor(String pixelFormat) =>
      pixelFormat.contains('10') ? 'p010le' : 'yuv420p';

  Future<MediaSpec?> _resolveTarget() async {
    if (_targetResolved) return _target;
    _targetResolved = true;
    try {
      _target = await targetSpec();
    } catch (e) {
      AppLog.warn('读不出原片规格，素材不做规格化：$e');
    }
    return _target;
  }

  Future<MediaSpec?> _probe(String path) async {
    if (!File(path).existsSync()) return null;
    try {
      final result = await run('ffprobe', MediaSpec.probeArgs(path));
      if (result.exitCode != 0) return null;
      return MediaSpec.tryParse('${result.stdout}');
    } catch (e) {
      AppLog.warn('读不出素材规格（$path）：$e');
      return null;
    }
  }
}
