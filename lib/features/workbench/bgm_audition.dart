import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/audio/bgm_plan.dart';
import '../../core/log/app_log.dart';
import '../../core/playback/playback_gate.dart';

/// 一个能出声的东西。抽出来是为了让测试不必碰 libmpv——试听的逻辑
/// （谁在响、换一条要不要先停）全在 [BgmAudition] 里，跟解码器无关。
abstract class AuditionPlayer {
  Future<void> open(String url);
  Future<void> dispose();
}

typedef AuditionPlayerFactory = AuditionPlayer Function();

/// 真实实现：media_kit 播一条远端音频。
class MediaKitAuditionPlayer implements AuditionPlayer {
  final Player _player = Player();

  /// 与时间线、候选试看同一道保险：还没打开完就销毁，会在 mpv 跑 loadlist
  /// 的当口抽掉它的配置，整个进程 abort
  final PlaybackGate _gate = PlaybackGate();

  @override
  Future<void> open(String url) => _gate.run(() => _player.open(Media(url)));

  @override
  Future<void> dispose() async => _gate.close(_player.dispose);
}

final auditionPlayerFactoryProvider = Provider<AuditionPlayerFactory>(
    (ref) => MediaKitAuditionPlayer.new);

/// 配乐试听：**同时只响一条**。
///
/// 挑配乐光看名字和时长挑不出来——「快乐的尤克里里」到底轻快到什么程度、
/// 压在口播下面吵不吵，只能听。两条同时响则完全没法比，所以换一条之前
/// 一定先把上一条收掉。
class BgmAudition extends ChangeNotifier {
  final AuditionPlayerFactory createPlayer;

  AuditionPlayer? _player;
  int? _playingId;
  String? _error;
  bool _shutdown = false;

  BgmAudition({required this.createPlayer});

  /// 当前在响的那条的 id；没有就是 null
  int? get playingId => _playingId;

  /// 上一次操作的人话错误；成功播放会清掉
  String? get error => _error;

  /// 点了某条的播放键：在响就停，没响就换成它。
  Future<void> toggle(BgmMaterial material) async {
    if (_shutdown) return;
    if (_playingId == material.id) {
      await stop();
      return;
    }
    await stop();
    if (_shutdown) return;

    final url = material.previewUrl;
    if (url == null || url.isEmpty) {
      _error = '这条配乐没有可播放的地址，试听不了';
      _notify();
      return;
    }

    final player = createPlayer();
    _player = player;
    _playingId = material.id;
    _error = null;
    _notify();

    try {
      await player.open(url);
    } catch (e) {
      AppLog.warn('配乐试听失败：$e');
      // 只有当前还是这一条时才回退：期间用户可能已经点了别的
      if (_playingId != material.id) return;
      _player = null;
      _playingId = null;
      _error = '这条配乐播不出来，可能是预览地址已过期';
      _notify();
      await player.dispose();
    }
  }

  Future<void> stop() async {
    final player = _player;
    _player = null;
    if (_playingId != null) {
      _playingId = null;
      _notify();
    }
    await player?.dispose();
  }

  /// 浮层关闭时调用：收走播放器，之后再点按钮也不会再出声。
  ///
  /// 与 [dispose] 分开，是因为 `ChangeNotifier.dispose` 之后不许再
  /// `notifyListeners`，而停播必须是可 await 的——两件事挤在一个同步方法里
  /// 只能靠 fire-and-forget，浮层关掉后那条歌还会响一会儿。
  Future<void> shutdown() async {
    if (_shutdown) return;
    _shutdown = true;
    final player = _player;
    _player = null;
    _playingId = null;
    await player?.dispose();
  }

  void _notify() {
    if (_shutdown) return;
    notifyListeners();
  }
}
