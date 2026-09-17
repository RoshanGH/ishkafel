import 'dart:async';
import 'dart:io';

import '../core/storage/ui_where.dart';

/// **委派是首选路径，不是必经之路。**
///
/// 「界面在场时写操作委派给界面」这条原则保留——它保证人看到的和落盘的同源，
/// 这个项目在「同一件事两处算」上栽过不止三次。改的是它的地位：
///
/// 以前是「委派 → 等界面 90 秒 → 超时 → 报『界面没有回应』」，于是可视化
/// 成了执行路径的一部分，一出问题就把 Agent 挡住。因果是反的。
///
/// 现在：
/// 1. **先读一眼界面在哪**。不在这条任务上就根本不委派，直接自己干、零等待
/// 2. 走委派的，[timeout] 是秒级（默认 2 秒），不是 90 秒
/// 3. 没应就自己干，**绝不返回失败**
///
/// 第 1 条不能省：少了它，界面没开的时候每条写命令都要白等 2 秒——47 镜挑
/// 下来就是一分半纯等待。**委派只在人确实看着的时候才有意义。**
/// 下单之后等回执该等多久——**必须比外层那个超时短一点**。
///
/// 一样长（或更长）的话，外层可能先到、直接走 `myself()` 自己干，
/// 而**那张单子还挂在盘上**：界面随时可能取走再做一遍，人看到两份。
/// 短一点，`viaUi` 就有机会在超时那一刻把单子 `consumeAgentRequest` 收回来。
///
/// 真机上 export 撞过这个（外 30s 内 30s）；apply plans / review 更反
/// ——外 2 秒、内 20 秒，外层必先到，单子在盘上还要挂 18 秒。
Duration withdrawBefore(Duration outer) {
  final inner = outer - const Duration(milliseconds: 400);
  return inner < const Duration(milliseconds: 200)
      ? Duration(microseconds: outer.inMicroseconds ~/ 2)
      : inner;
}

Future<T> delegateOrDoItYourself<T>({
  required Directory dataDir,
  required String? taskId,

  /// 请界面代办。它没接单、或者干不了就返回 null
  required Future<T?> Function() viaUi,

  /// 自己干。**这条路永远存在，也永远成功或按真实原因失败**
  required Future<T> Function() myself,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final onScene = taskId != null &&
      readUiWhere(dataDir)?.isOnTask(taskId) == true;
  if (!onScene) return myself();

  try {
    // 不用 `Future.timeout`：它的 onTimeout 在这种「T 由外层泛型推导出来」
    // 的场景下会把 `() => null` 错误推断成不可空类型，运行时抛
    // 「type '() => Null' is not a subtype」——手写一个不依赖它的计时器
    final completer = Completer<T?>();
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    unawaited(viaUi().then((value) {
      timer.cancel();
      if (!completer.isCompleted) completer.complete(value);
    }, onError: (Object e, StackTrace st) {
      timer.cancel();
      if (!completer.isCompleted) completer.completeError(e, st);
    }));
    final viaUiResult = await completer.future;
    if (viaUiResult != null) return viaUiResult;
  } catch (_) {
    // 委派这条路出任何岔子都不该拖累正事——自己干就是了
  }
  return myself();
}
