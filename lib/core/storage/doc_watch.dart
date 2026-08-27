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
