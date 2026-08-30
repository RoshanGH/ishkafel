import 'dart:io';

/// presence 目录里哪些是**任务的在场文件**。
///
/// 这个目录里还住着别的东西：`<任务>.ack.json`（界面的回执）、
/// `__app__.request-result.json`（请界面代办的结果）。把它们也当成任务 id，
/// 读出来的在场状态永远是 null——而扫描遇到第一个非 null 就停，
/// 于是真正在干活的那条被挡在后面，播报条一片空白（真机撞到过）。
Iterable<String> presenceTaskIds(Directory dataDir) {
  try {
    final dir = Directory('${dataDir.path}/presence');
    if (!dir.existsSync()) return const [];
    return [
      for (final f in dir.listSync())
        ?_taskIdOf(f.uri.pathSegments.last),
    ];
  } catch (_) {
    return const [];
  }
}

String? _taskIdOf(String fileName) {
  if (!fileName.endsWith('.json')) return null;
  final stem = fileName.substring(0, fileName.length - '.json'.length);
  // 回执、请求结果这类旁支文件的名字里都带一个点，任务 id 里没有
  if (stem.contains('.')) return null;
  return stem;
}
