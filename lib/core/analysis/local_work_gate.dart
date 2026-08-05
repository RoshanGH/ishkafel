import 'dart:async';
import 'dart:io';

/// 本地重活（ffmpeg 抽帧、解码）的并发闸。
///
/// **云端调用不限并发**——服务端自己会排队，实测并发 24 也不限流，我们没理由
/// 替它省。但本地这一头不一样：58 个镜头各要抽 3 帧，一次性放出去就是 174 个
/// ffmpeg 进程同时抢 8 个核，互相拖慢，总时间反而更长。
///
/// 所以闸门只拦本地部分，放行数 = 核心数。
class LocalWorkGate {
  final int permits;
  int _inUse = 0;
  final _waiting = <Completer<void>>[];

  LocalWorkGate({int? permits})
      : permits = permits ?? Platform.numberOfProcessors;

  /// 默认闸：整个进程共用一个，避免各处各开一套把机器压垮
  static final LocalWorkGate shared = LocalWorkGate();

  Future<T> run<T>(Future<T> Function() work) async {
    if (_inUse >= permits) {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      await waiter.future;
    }
    _inUse++;
    try {
      return await work();
    } finally {
      _inUse--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}
