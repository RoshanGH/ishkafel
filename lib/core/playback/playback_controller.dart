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

  /// 播放 [startMs, endMs) 并**由播放器自己**在终点停住。
  ///
  /// 为什么必须交给播放器：在外面盯位置流判「到点了没」，采样粒度决定了它
  /// 必然过头几十毫秒，再 seek 回去就是一次肉眼可见的回跳。用户要的是一帧
  /// 一帧正常播到最后一帧然后停，不是播过了再倒带。
  ///
  /// 返回 false 表示当前实现没有这个能力，调用方据此降级（不要假装停得住）。
  Future<bool> playRange(int startMs, int endMs, double fps);

  /// 解除区间限制，恢复成一直往下播
  Future<void> clearRange();

  /// 按帧步进（暂停态逐帧）：`frames` 为正前进、为负后退，`fps` 为素材帧率。
  Future<void> stepFrames(int frames, double fps);

  /// 播放位置流（毫秒）。
  Stream<int> get positionMsStream;

  /// 播放/暂停状态流：随 [play]/[pause] 或任何外部原因（如播放到片尾自动
  /// 暂停）变化而推送最新值，供 UI 保持图标与真实状态同步，而不是靠本地
  /// 变量盲目翻转。
  Stream<bool> get playingStream;

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
  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();

  int _positionMs = 0;
  bool _isPlaying = false;

  @override
  Future<void> open(String path) async {
    calls.add('open($path)');
    _positionMs = 0;
    _isPlaying = false;
    _positionController.add(_positionMs);
    _playingController.add(_isPlaying);
  }

  @override
  Future<void> play() async {
    calls.add('play()');
    _isPlaying = true;
    _playingController.add(_isPlaying);
  }

  @override
  Future<void> pause() async {
    calls.add('pause()');
    _isPlaying = false;
    _playingController.add(_isPlaying);
  }

  @override
  Future<void> seekMs(int ms) async {
    calls.add('seekMs($ms)');
    _positionMs = math.max(0, ms);
    _positionController.add(_positionMs);
  }

  /// 是否具备区间播放能力（测试可置 false 来验证降级路径）
  bool supportsRange = true;

  @override
  Future<bool> playRange(int startMs, int endMs, double fps) async {
    calls.add('playRange($startMs, $endMs)');
    if (!supportsRange) return false;
    await seekMs(startMs);
    await play();
    return true;
  }

  @override
  Future<void> clearRange() async => calls.add('clearRange()');

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
  Stream<bool> get playingStream => _playingController.stream;

  @override
  int get positionMs => _positionMs;

  @override
  bool get isPlaying => _isPlaying;

  @override
  Future<void> dispose() async {
    calls.add('dispose()');
    await _positionController.close();
    await _playingController.close();
  }
}
