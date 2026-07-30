import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
