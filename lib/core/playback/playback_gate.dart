import 'dart:async';

import '../log/app_log.dart';

/// 播放器命令与销毁之间的闸门。
///
/// 存在的理由是一次真实崩溃：用户在视频还没打开完时点「返回」，页面 dispose
/// 里把 mpv 实例销毁掉，而 mpv 的工作线程还在跑那条 loadlist 命令——它取
/// 配置时发现全局配置已经被释放，直接 `assert` 失败，整个进程 `SIGABRT`。
/// 用户看到的是「返回后再点一个任务就闪退」。
///
/// 这里不串行化命令（seek 与 play 本来就该能同时发出），只做两件事：
/// 数着还有几条命令在路上，销毁时等它们回来；销毁之后来的命令直接丢弃。
class PlaybackGate {
  int _inFlight = 0;
  final List<Completer<void>> _idleWaiters = [];
  bool _closed = false;

  bool get isClosed => _closed;

  /// 跑一条播放器命令。
  ///
  /// 已经销毁后返回 null 而不是假装成功——调用方据此降级（例如 playRange
  /// 返回 false 让上层走兜底），比拿到一个骗人的成功强。
  Future<T?> run<T>(Future<T> Function() action) async {
    if (_closed) return null;
    _inFlight++;
    try {
      return await action();
    } finally {
      _inFlight--;
      if (_inFlight == 0) {
        for (final waiter in _idleWaiters) {
          if (!waiter.isCompleted) waiter.complete();
        }
        _idleWaiters.clear();
      }
    }
  }

  /// 等在跑的命令收尾，再执行 [teardown]。重复调用只销毁一次。
  ///
  /// [timeout] 是保险丝：某条命令若永远不回来，宁可泄漏一个播放器实例，
  /// 也不能让退出流程永远挂在这里。
  Future<void> close(
    Future<void> Function() teardown, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_closed) return;
    _closed = true;
    if (_inFlight > 0) {
      final idle = Completer<void>();
      _idleWaiters.add(idle);
      try {
        await idle.future.timeout(timeout);
      } on TimeoutException {
        AppLog.warn('播放器命令超时未收尾，仍继续销毁（可能泄漏一个实例）');
      }
    }
    await teardown();
  }
}
