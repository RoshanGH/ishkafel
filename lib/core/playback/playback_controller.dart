import 'dart:async';
import 'dart:math' as math;

/// 播放控制抽象：UI 只依赖它，测试注入 [FakePlaybackController]，
/// 生产环境注入 `MediaKitPlaybackController`。
abstract class PlaybackController {
  /// 打开并暂停在首帧。
  Future<void> open(String path);

  /// 开始播放。
  Future<void> play();

  /// 暂停播放。
  Future<void> pause();

  /// 跳转到指定毫秒位置。
  Future<void> seekMs(int ms);

  /// 按帧步进（暂停态逐帧）：`frames` 为正前进、为负后退，`fps` 为素材帧率。
  Future<void> stepFrames(int frames, double fps);

  /// 播放位置流（毫秒）。
  Stream<int> get positionMsStream;

  /// 当前播放位置（毫秒）。
  int get positionMs;

  /// 是否正在播放。
  bool get isPlaying;

  /// 释放底层资源。
  Future<void> dispose();
}

/// 测试替身：内存位置模拟，记录调用，零 libmpv 依赖。
class FakePlaybackController implements PlaybackController {
  final List<String> calls = [];

  final StreamController<int> _positionController =
      StreamController<int>.broadcast();

  int _positionMs = 0;
  bool _isPlaying = false;

  @override
  Future<void> open(String path) async {
    calls.add('open($path)');
    _positionMs = 0;
    _isPlaying = false;
    _positionController.add(_positionMs);
  }

  @override
  Future<void> play() async {
    calls.add('play()');
    _isPlaying = true;
  }

  @override
  Future<void> pause() async {
    calls.add('pause()');
    _isPlaying = false;
  }

  @override
  Future<void> seekMs(int ms) async {
    calls.add('seekMs($ms)');
    _positionMs = math.max(0, ms);
    _positionController.add(_positionMs);
  }

  @override
  Future<void> stepFrames(int frames, double fps) async {
    calls.add('stepFrames($frames, $fps)');
    final deltaMs = (1000 / fps).round() * frames;
    _positionMs = math.max(0, _positionMs + deltaMs);
    _positionController.add(_positionMs);
  }

  @override
  Stream<int> get positionMsStream => _positionController.stream;

  @override
  int get positionMs => _positionMs;

  @override
  bool get isPlaying => _isPlaying;

  @override
  Future<void> dispose() async {
    calls.add('dispose()');
    await _positionController.close();
  }
}
