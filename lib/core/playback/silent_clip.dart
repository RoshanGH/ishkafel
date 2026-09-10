/// 预览用的**等长静音**。
///
/// 「原片这一镜的声音」选了「不播放」时，口播轨那一段不能少拼——多轨预览走
/// mpv 的 `edl://`，而 EDL 没有「空档」：留洞会被压掉，从那儿起后面所有内容
/// 提前一截，时间线和播放器就此对不上（黑场垫片踩过同一个坑，见 [GapClip]）。
/// EDL 也表达不了「这一段音量为 0」，所以只能真给它一段静音。
///
/// **不做时长取整**：黑场那边取整到 100ms 是因为它只是占位；这里差 50ms
/// 就是口播轨对不上画面，那是能听出来的。
library;

import 'dart:io';

import '../ffmpeg/rendered_cache.dart';

class SilentClip {
  final RenderedCache cache;

  const SilentClip(this.cache);

  static String _key(int durationMs) => 'silent|$durationMs';

  Future<String?> render({required int durationMs}) async {
    if (durationMs <= 0) return null;
    try {
      return await cache.render(
        key: _key(durationMs),
        prefix: 'silent',
        extension: 'wav',
        args: (dest) => [
          '-y', '-v', 'error',
          '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo',
          '-t', (durationMs / 1000).toStringAsFixed(3),
          dest,
        ],
        what: '给「不放原片声音」的那一镜垫静音',
      );
    } on Object {
      // 垫不出来就退回原声：这是**预览**，位置对不上比声音多一层更糟。
      // 导出那条路不走这里，它一定是真静音
      return null;
    }
  }

  /// 这一份在不在盘上（在的话当轮就能用，不必等渲染）
  String? existing({required int durationMs}) {
    if (durationMs <= 0) return null;
    final path = cache.pathFor(
        key: _key(durationMs), prefix: 'silent', extension: 'wav');
    final file = File(path);
    return file.existsSync() && file.lengthSync() > 0 ? path : null;
  }
}
