import 'dart:io';

import '../ffmpeg/media_spec.dart';
import '../ffmpeg/rendered_cache.dart';

/// 给「还没挑素材」的那一段垫一小片黑场。
///
/// **为什么非垫不可**：预览走 mpv 的 `edl://`，而 EDL 没有「空档」这个概念
/// ——段与段首尾相接，留洞会被直接压掉，从那儿起后面所有内容都提前一截
/// （见 `Edl._warnIfHoles`）。于是时间线画到 01:47、播放器只走到 01:37，
/// 双击最后一格跳过去落在片尾（2026-09-08 真机：「U6 不能正常播放」）。
///
/// 垫的是黑场而不是随便找一帧：那一段**本来就什么都没有**，人要看到的正是
/// 「这儿是空的」。同时播放头一进这段就会停下来点名（见 `TrackPlan.unplayable`），
/// 所以他不会对着黑屏猜。
///
/// 产物按「规格 + 时长」缓存，同一条片子里几段同长的空位共用一份。
class GapClip {
  final RenderedCache cache;

  const GapClip(this.cache);

  /// 时长取整到 100ms：几段空位常常只差几毫秒，取整能让它们命中同一份产物，
  /// 少跑几次 ffmpeg。误差最多 50ms，而这一段本来就是占位
  static int bucketMs(int durationMs) => (durationMs / 100).round() * 100;

  Future<String?> render({
    required int durationMs,
    required MediaSpec? spec,
  }) async {
    if (durationMs <= 0) return null;
    final ms = bucketMs(durationMs);
    if (ms <= 0) return null;
    final width = spec?.width ?? 720;
    final height = spec?.height ?? 1280;
    final fps = spec?.frameRate ?? '30';
    final key = 'gap|$width x$height|$fps|$ms';
    try {
      return await cache.render(
        key: key,
        prefix: 'gap',
        extension: 'mp4',
        args: (dest) => [
          '-y', '-v', 'error',
          // 黑场画面
          '-f', 'lavfi',
          '-i', 'color=c=black:s=${width}x$height:r=$fps',
          // 配一条静音：声音轨那边同样不能留洞，留洞的表现是
          // 「最后几个字一直重复」（真机反馈，排查了两轮才定位到）
          '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo',
          '-t', (ms / 1000).toStringAsFixed(3),
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'ultrafast',
          '-c:a', 'aac',
          '-shortest',
          dest,
        ],
        what: '给还没挑素材的那一段垫黑场',
      );
    } on Object {
      // 垫不出来就退回「留洞」：位置会错，但至少还能播——而洞本身
      // Edl 会打警告，不会无声无息
      return null;
    }
  }

  /// 这一份产物在不在盘上（在的话可以立刻用，不必等渲染）
  String? existing({required int durationMs, required MediaSpec? spec}) {
    final ms = bucketMs(durationMs);
    if (ms <= 0) return null;
    final width = spec?.width ?? 720;
    final height = spec?.height ?? 1280;
    final fps = spec?.frameRate ?? '30';
    final path = cache.pathFor(
        key: 'gap|$width x$height|$fps|$ms', prefix: 'gap', extension: 'mp4');
    final file = File(path);
    return file.existsSync() && file.lengthSync() > 0 ? path : null;
  }
}
