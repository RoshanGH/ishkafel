import 'dart:async';
import 'dart:io';

import '../../core/storage/agent_presence.dart';

/// 「软件自己在这条任务上跑活儿」这份状态的持有者。
///
/// 三件事它要替调用方管住，散着写每一件都出过岔子：
///
/// 1. **心跳。** 在场状态 60 秒过期，而一句 TTS、一镜识图常常超过它。
///    没有心跳，这份状态会在**最贵的那一段**失效，
///    `busy_guard` 那道「别把同一件贵活儿跑两遍」的劝告就白加了
/// 2. **嵌套不留缝。** 批量活儿（自动铺一版、批量重配）在整轮外面挂一层，
///    里面每一句再各挂一层。**逐句 `写→撤` 之间是有缝的**——那一瞬
///    `.app.json` 不存在，Agent 的 `script voice` 正好在缝里起来就不会被
///    劝退，整轮双份计费。所以用一个**标签栈**：栈没空就不撤
/// 3. **话不能变空。** 一度用「进场时拍个快照、退场还原」的写法：两层交叉
///    释放时，先释放那个会把话还原成它进场时的空串，于是 `.app.json` 还在、
///    `action` 却成了空串，`busy_guard` 的关键词匹配当场失配——
///    **状态还在、劝告已经瞎了**，比文件消失更难发现。栈天然没有这个问题：
///    退一层就露出下面那一层的话
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

  /// 还挂着的那几层活儿，栈顶是此刻在说的那一句
  final List<_Layer> _stack = [];
  Timer? _pulse;

  /// 代次。[dispose] 之后 +1，**把已经发出去的收工回调全部作废**。
  ///
  /// 不作废的话：页面拆了之后遗留的回调还会进来减一次计数，把它减成负数，
  /// 此后 enter/exit 配对全乱；而多出来的那一次收工会 `clearAppBusy`，
  /// 而这份文件**有第二个写入方**（任务列表那边的分析）——
  /// 于是一个已经销毁的页面可能抹掉别人正在跑的活儿的状态
  int _generation = 0;

  /// **我写过、而且还没清。**
  ///
  /// 没有这一位的话，`dispose()` / `_stop()` 会无条件 `clearAppBusy`——
  /// 栈本来就空（这一页一次活儿都没跑过）时关掉页面，照样把文件删掉。
  /// 而这份文件**有第二个写入方**（任务列表那边的分析）：于是关一下编导台
  /// 就可能抹掉别人正在跑的活儿的状态。
  ///
  /// 代次作废堵的是「遗留回调」那道门，这一位堵的是 `dispose` 那道门
  /// ——同一个危害的两条路。
  bool _wrote = false;

  /// 此刻正挂着的那句话；没挂就是 null
  String? get current => _stack.isEmpty ? null : _stack.last.what;

  /// 还挂着几层。测试用
  int get depth => _stack.length;

  /// 开工。返回的回调**必须在 `finally` 里调**。
  ///
  /// 重复调同一个回调是安全的（只认第一次）；[dispose] 之后再调也是安全的
  /// （那一代已经作废）——调用方不必自己记状态。
  void Function() enter(String what) {
    final layer = _Layer(what);
    final generation = _generation;
    _stack.add(layer);
    _write();
    _pulse ??= Timer.periodic(pulseEvery, (_) => _write());
    var released = false;
    return () {
      if (released) return;
      released = true;
      // 这一层属于上一代（页面已经拆了）：什么都不做，
      // 尤其不许 clearAppBusy——那份文件可能正被别人用着
      if (generation != _generation) return;
      _stack.remove(layer);
      if (_stack.isEmpty) {
        _stop();
        return;
      }
      // 外层还开着：话换回栈顶那一句，状态继续挂着，**中间不留缝**
      _write();
    };
  }

  /// 页面拆了：无论嵌套到第几层都收干净，并把已发出的回调全部作废。
  /// **`dispose` 里必须调**，否则那个周期性 Timer 会留在后面跑
  void dispose() {
    _generation++;
    _stack.clear();
    _stop();
  }

  void _stop() {
    _pulse?.cancel();
    _pulse = null;
    _stack.clear();
    // **只清自己写过的那一份**（见 [_wrote]）
    if (!_wrote) return;
    _wrote = false;
    clearAppBusy(dataDir: dataDir, taskId: taskId);
  }

  void _write() {
    final what = current;
    if (what == null) return;
    _wrote = true;
    writeAppBusy(
      dataDir: dataDir,
      taskId: taskId,
      busy: AgentPresence(holder: holder, at: DateTime.now(), action: what),
    );
  }
}

class _Layer {
  final String what;
  _Layer(this.what);
}
