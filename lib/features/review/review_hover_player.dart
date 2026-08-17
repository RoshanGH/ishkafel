import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/log/app_log.dart';
import '../../core/playback/edl.dart';
import '../../core/playback/playback_gate.dart';
import '../../core/playback/track_plan.dart';

/// 悬停试播的播放器。抽成接口是为了让 widget 测试注入假实现——
/// 真实现要碰 libmpv，测试环境没有。
///
/// **整页共用一个实例**：审核页上有十几张卡，每张各建一个 mpv 实例会把
/// 内存吃穿；悬停本来就一次只有一张卡在播。
abstract class ReviewHoverPlayer {
  /// 播放一个本地文件（循环、有声——审核听的就是素材自带的声音）。
  /// 给了 [startMs]/[endMs] 就只播这个区间——原片卡播的是「这一段」，
  /// 不是从头放整条片子
  Future<void> play(String path, {int? startMs, int? endMs});

  Future<void> stop();

  /// 嵌进当前悬停卡片里的画面
  Widget buildVideo();

  void dispose();
}

class MediaKitHoverPlayer implements ReviewHoverPlayer {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  /// 与其余播放器同一道保险：打开进行中就销毁会让 mpv 整个进程 abort
  final PlaybackGate _gate = PlaybackGate();

  @override
  Future<void> play(String path, {int? startMs, int? endMs}) async {
    try {
      // 区间播放走 edl：mpv 认它，且与预览合成同一套机制
      final source = (startMs != null && endMs != null && endMs > startMs)
          ? Edl.of([
              TrackSegment(
                  atMs: 0,
                  durationMs: endMs - startMs,
                  source: path,
                  inMs: startMs),
            ])!
          : path;
      await _gate.run(() async {
        await _player.open(Media(source));
        await _player.setPlaylistMode(PlaylistMode.single);
      });
    } catch (e) {
      AppLog.warn('悬停试播失败（$path）：$e');
    }
  }

  @override
  Future<void> stop() => _gate.run(_player.stop);

  @override
  Widget buildVideo() =>
      Video(controller: _controller, controls: NoVideoControls);

  @override
  void dispose() {
    _gate.run(_player.dispose);
  }
}
