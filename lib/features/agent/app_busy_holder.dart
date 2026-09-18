import 'dart:async';
import 'dart:io';

import '../../core/storage/agent_presence.dart';

/// 「软件自己在这条任务上跑活儿」这份状态的持有者。
///
/// 两件事它要替调用方管住，散着写都会出岔子：
///
/// 1. **心跳。** 在场状态 60 秒过期，而一句 TTS、一镜识图常常超过它。
///    没有心跳，这份状态会在**最贵的那一段**失效，
///    `busy_guard` 那道「别把同一件贵活儿跑两遍」的劝告就白加了
/// 2. **嵌套不留缝。** 批量活儿（自动铺一版、批量重配）在整轮外面开一层，
///    里面每一句再各开一层。**逐句 `写→撤` 之间是有缝的**——那一瞬
///    `.app.json` 不存在，Agent 的 `script voice` 正好在缝里起来就不会被
///    劝退，整轮双份计费。所以按嵌套深度计数：外层没退就不撤
///
/// 它**不写 Agent 那份在场状态**（播报通道）。CLAUDE.md：「播报只报 Agent
/// 在做什么。软件自己跑的活儿不许占那条通道——占了，人就分不清是谁在动手。」
class AppBusyHolder {
  final Directory dataDir;
  final String taskId;

  /// 横幅/`status` 上说得出的名字，比如「软件（编导台）」
  final String holder;

  /// 多久补一次。默认 20 秒 = [defaultStaleAfter] 的三分之一，
  /// 丢一两拍也不会过期。测试注入更短的值
  final Duration pulseEvery;

  AppBusyHolder({
    required this.dataDir,
    required this.taskId,
    required this.holder,
    this.pulseEvery = const Duration(seconds: 20),
  });

  int _depth = 0;
  Timer? _pulse;
  String _what = '';

  /// 此刻正挂着的那句话；没挂就是 null。测试与调试用
  String? get current => _depth == 0 ? null : _what;

  /// 开工。返回的回调**必须在 `finally` 里调**。
  ///
  /// 重复调同一个回调是安全的（只认第一次）——那样调用方不必自己记状态。
  VoidCallback enter(String what) {
    final previous = _what;
    _what = what;
    _depth++;
    _write();
    _pulse ??= Timer.periodic(pulseEvery, (_) => _write());
    var released = false;
    return () {
      if (released) return;
      released = true;
      _depth--;
      if (_depth > 0) {
        // 外层还开着：把话换回去，状态继续挂着，**中间不留缝**
        _what = previous;
        _write();
        return;
      }
      _stop();
    };
  }

  /// 页面拆了：无论嵌套到第几层都收干净。**`dispose` 里必须调**，
  /// 否则那个周期性 Timer 会留在后面跑
  void dispose() {
    _depth = 0;
    _stop();
  }

  void _stop() {
    _pulse?.cancel();
    _pulse = null;
    _what = '';
    clearAppBusy(dataDir: dataDir, taskId: taskId);
  }

  void _write() => writeAppBusy(
        dataDir: dataDir,
        taskId: taskId,
        busy:
            AgentPresence(holder: holder, at: DateTime.now(), action: _what),
      );
}

/// `VoidCallback` 在这一层不想为了一个类型去 import flutter/material
typedef VoidCallback = void Function();
