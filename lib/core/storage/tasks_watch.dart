import 'dart:io';

import 'package:path/path.dart' as p;

/// 盘上的任务清单**指纹**：数量 + 各自的大小与修改时间。
///
/// 存在理由是一条真机 bug：Agent 在外面用 CLI 建了一条任务、或者改完了
/// 一条任务，**正开着的界面完全不知道**——列表只在进页面那一刻读过一次。
/// 用户看到的是「命令说建好了，界面上什么都没有」，只能退出去重进。
///
/// 这不是可视模式才需要的：静默模式下人回头来看，也该看得到。
///
/// 为什么是指纹而不是文件监听：跨平台的目录监听在 macOS 上对「原子替换」
/// （写临时文件再 rename，正是任务落盘的做法）表现不一致，容易漏事件。
/// 一秒算一次指纹的代价可以忽略——只 stat 不读内容。
String tasksFingerprint(Directory dataDir) {
  final dir = Directory(p.join(dataDir.path, 'tasks'));
  if (!dir.existsSync()) return 'none';
  final parts = <String>[];
  try {
    for (final e in dir.listSync()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      final s = e.statSync();
      parts.add('${p.basename(e.path)}:${s.size}:'
          '${s.modified.millisecondsSinceEpoch}');
    }
  } catch (_) {
    return 'error';
  }
  parts.sort();
  return parts.join('|');
}
