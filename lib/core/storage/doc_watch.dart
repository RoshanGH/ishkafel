import 'dart:io';

import 'package:path/path.dart' as p;

/// 单个任务在盘上的**指纹**（大小 + 修改时间）。
///
/// 用来解决两个真机问题，它们其实是同一件事的两面：
///
/// 1. **假阳性丢写**：Agent 可视模式改台词，界面被唤醒打开时内存里还是
///    旧数据；之后界面任何一次自动保存都会把整份旧 doc 写回去，盖掉
///    Agent 刚写的东西——CLI 报 `ok:true`，盘上却没变
/// 2. **界面不跟随数据**：Agent 改了什么，界面完全不刷新。可视模式做了
///    「滚到那一行」却没做「显示新内容」，人看着的是一块不动的板子
///
/// 只 stat 不读内容，500ms 一次的代价可以忽略。
String taskFingerprint(Directory dataDir, String taskId) {
  final f = File(p.join(dataDir.path, 'tasks', '$taskId.json'));
  try {
    if (!f.existsSync()) return 'none';
    final s = f.statSync();
    return '${s.size}:${s.modified.microsecondsSinceEpoch}';
  } catch (_) {
    return 'error';
  }
}

/// 界面现在能安全地把内存里的数据整份写回去吗。
///
/// [loadedPrint] 是界面**上次读到这份数据时**的指纹。对得上说明这期间
/// 没人动过盘，可以写；对不上说明外面（Agent）改过，照写就会盖掉别人
/// 刚写的东西。
///
/// 为什么不用「Agent 在场时不写」来挡：那个「在场」是 500ms 轮询出来的，
/// 窗口里界面照写不误。真机连着两轮都栽在这儿——第二轮更狠，
/// 把**已经落盘很久**的一句台词回滚没了，而 CLI 全程 `ok:true`。
///
/// 按内容判定不依赖任何时序，这是它比「看在场状态」可靠的地方。
bool canOverwrite(Directory dataDir, String taskId, String? loadedPrint) {
  if (loadedPrint == null) return true; // 还没读过，谈不上被人改
  final now = taskFingerprint(dataDir, taskId);
  if (now == 'none') return true; // 文件还不存在：这是第一次落盘
  return now == loadedPrint;
}

/// 界面自己写完一次盘之后，基线该不该推到「写完之后」那一份。
///
/// [current] 是写之前的基线，[before] 是**紧挨着那次写**取的现盘指纹，
/// [after] 是写完之后的。
///
/// **只有 `before == current`（这段窗口里没有别人写过）才推。** 否则就是
/// 推过别人那一笔——跟随从此判「没变」不再重读（**Agent 那一笔人永远看不到**），
/// 而人下一次保存 `canOverwrite` 为真、**整份内容静默盖过去**。
///
/// 为什么会有这个窗口：编导台保存完会顺手换一张封面（`ensureScriptCover`
/// 要抽帧，**可能是秒级**），而封面也写同一个 `tasks/<id>.json`。不推基线的话，
/// 本页自己的封面写入会把下一次真改动误判成「Agent 改过」；无条件推，
/// 就会把这段窗口里 Agent 的写入一并推过去。
///
/// 宁可让下一次保存被自己的封面挡一下（人看得见、有出路），
/// 也不能静默盖掉别人的活。
String? advanceBaselineAfterOwnWrite({
  required String? current,
  required String before,
  required String after,
}) =>
    before == current ? after : current;
