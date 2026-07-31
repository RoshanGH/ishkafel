import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../log/app_log.dart';
import 'playback_controller.dart';

/// media_kit 实现（薄封装 [Player]）；`Video` 组件由 player_panel 使用。
class MediaKitPlaybackController implements PlaybackController {
  MediaKitPlaybackController({Player? player})
      : player = player ?? Player() {
    _videoController = VideoController(this.player);
  }

  /// media_kit 底层播放器实例。
  final Player player;

  late final VideoController _videoController;

  @override
  Future<void> open(String path) async {
    await player.open(Media(path), play: false);
    // 播到文件结尾（或区间终点）时停在最后一帧，而不是卸载文件后黑屏。
    // 只设一次，之后区间播放只管改 `end`。
    await _setMpv('keep-open', 'yes');
  }

  /// 交给 mpv 自己在终点停：设 `end` 后播放器会正常播到该时间点前的最后
  /// 一帧然后暂停。在 Dart 层盯位置流判断「到点了没」做不到这一点——采样
  /// 粒度决定了它必然过头几十毫秒，再 seek 回去就是一次可见的回跳。
  @override
  Future<bool> playRange(int startMs, int endMs) async {
    if (endMs <= startMs) return false;
    // 先定位再设终点：反过来的话，当前位置若已在终点之后，mpv 会立刻判 EOF
    await seekMs(startMs);
    final ok = await _setMpv('end', _mpvSeconds(endMs));
    if (!ok) return false;
    await play();
    return true;
  }

  @override
  Future<void> clearRange() async => _setMpv('end', 'none');

  /// mpv 的时间值用秒（小数）。毫秒整数除以 1000 保三位小数即可无损。
  static String _mpvSeconds(int ms) => (ms / 1000).toStringAsFixed(3);

  /// 设置 libmpv 属性；非原生实现或调用失败时返回 false 交由调用方降级，
  /// 不让一次属性设置失败把整个播放动作带崩
  Future<bool> _setMpv(String name, String value) async {
    final native = player.platform;
    if (native is! NativePlayer) return false;
    try {
      await native.setProperty(name, value);
      return true;
    } catch (e) {
      AppLog.warn('设置播放器属性失败（$name=$value）：$e');
      return false;
    }
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seekMs(int ms) => player.seek(Duration(milliseconds: ms));

  @override
  Future<void> stepFrames(int frames, double fps) async {
    await player.pause();
    final deltaMs = (1000 / fps).round() * frames;
    final targetMs = math.max(0, positionMs + deltaMs);
    await player.seek(Duration(milliseconds: targetMs));
  }

  @override
  Stream<int> get positionMsStream =>
      player.stream.position.map((d) => d.inMilliseconds);

  @override
  Stream<bool> get playingStream => player.stream.playing;

  @override
  int get positionMs => player.state.position.inMilliseconds;

  @override
  bool get isPlaying => player.state.playing;

  @override
  Future<void> dispose() => player.dispose();

  /// 构建视频画面组件：不带内置控制条，由外层（player_panel）自绘控制层。
  Widget buildVideoWidget() {
    return Video(
      controller: _videoController,
      controls: NoVideoControls,
    );
  }
}
