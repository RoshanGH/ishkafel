import 'package:media_kit/media_kit.dart';

import '../log/app_log.dart';
import '../playback/playback_gate.dart';

/// 试听一个本地音频文件（生成出来的配音）。
///
/// 与时间线的播放器分开：那一个正播着原片，试听配音时不该把它的位置弄丢。
/// 播放器实例懒创建——大多数用户一次都不会点试听，没必要为它常驻一个 mpv。
class AudioPreview {
  Player? _player;

  /// 与时间线播放器同一道保险：试听还没打开完就点返回，直接销毁会在 mpv
  /// 跑 loadlist 的当口抽掉它的配置，整个进程 abort（见 [PlaybackGate]）。
  final PlaybackGate _gate = PlaybackGate();

  /// 播一遍。重复调用会打断上一次——用户连点两个单元时，
  /// 两句配音叠着响是最糟的反馈。
  Future<void> play(String path) async {
    await _gate.run(() async {
      try {
        final player = _player ??= Player();
        await player.open(Media(path));
      } catch (e) {
        // 试听失败不该让页面崩：产物还在，用户仍可导出
        AppLog.warn('试听配音失败（$path）：$e');
        rethrow;
      }
    });
  }

  Future<void> stop() => _gate.run(() async => _player?.pause());

  Future<void> dispose() => _gate.close(() async {
        final player = _player;
        _player = null;
        await player?.dispose();
      });
}
