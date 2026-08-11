import 'dart:io';

import 'package:path/path.dart' as p;

/// app 的 bundle id。数据目录是按它分的，两边必须写同一个值
const String bundleId = 'com.jichuang.ishkafel';

/// CLI 用的数据目录，**必须与 GUI 完全一致**。
///
/// GUI 走 `path_provider` 的 `getApplicationSupportDirectory()`，在 macOS 上
/// 就是 `~/Library/Application Support/<bundle id>`。CLI 没有 Flutter
/// binding，只能按同样规则自己拼。
///
/// 两边一旦不一致，症状是最难查的那一类：Agent 建的任务在 app 里看不见、
/// app 里改的东西 Agent 读不到，而**谁都没有报错**。所以这条规则有测试钉着。
///
/// [override] 与 `ISHKAFEL_DATA_DIR` 供测试和多环境用；显式参数优先。
Directory resolveDataDir({Map<String, String>? env, String? override}) {
  final e = env ?? Platform.environment;
  final explicit = override ?? e['ISHKAFEL_DATA_DIR'];
  if (explicit != null && explicit.trim().isNotEmpty) {
    return Directory(explicit.trim());
  }
  final home = e['HOME'];
  if (home == null || home.trim().isEmpty) {
    // 拼一个错的路径会让 CLI 静默地在别处建任务，比直接失败难查得多
    throw StateError('读不到 HOME，无法定位数据目录；可用 ISHKAFEL_DATA_DIR 指定');
  }
  return Directory(
      p.join(home, 'Library', 'Application Support', bundleId, 'ishkafel_data'));
}
