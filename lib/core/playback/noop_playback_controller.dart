import 'playback_controller.dart';

/// 播放后端不可用时的降级替身：所有操作均安静地不做任何事。
///
/// 唯一使用场景：生产环境构造 `MediaKitPlaybackController` 失败时（例如
/// 目标机器缺 libmpv 动态库）的兜底——用它替换真实播放器，让审片台其余
/// 交互（切分编辑/确认流转）继续可用，而不是让整页崩溃。正常启动流程下
/// （`main()` 已调用 `MediaKit.ensureInitialized()`）不会触达这条路径。
class NoopPlaybackController implements PlaybackController {
  @override
  Future<void> open(String path) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekMs(int ms) async {}

  @override
  Future<void> stepFrames(int frames, double fps) async {}

  @override
  Stream<int> get positionMsStream => const Stream.empty();

  @override
  Stream<bool> get playingStream => const Stream.empty();

  @override
  int get positionMs => 0;

  @override
  bool get isPlaying => false;

  @override
  Future<void> dispose() async {}
}
