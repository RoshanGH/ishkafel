import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import 'task_list_controller.dart';

/// 源文件存在性探测：接受绝对路径，返回文件是否仍然存在。
///
/// 做成可注入的函数而不是直接调 `File.exists`，是为了让 UI 测试不必依赖
/// 真实文件系统。
typedef FileExistsProbe = Future<bool> Function(String path);

final fileExistsProbeProvider =
    Provider<FileExistsProbe>((ref) => (path) => File(path).exists());

/// 源文件已不存在的任务 id 集合。
///
/// `sourcePath` 是绝对路径且写进任务 JSON，文件被删/改名后封面变黑块、
/// 进审片台播放器黑屏、时间线空白，全程没有一句「源文件已不存在」。
///
/// 探测放在 provider 里而不是卡片 `build` 里：`GridView.builder` 滚动时每帧
/// 都会重建可见卡片，在 build 里做同步 `existsSync` 等于每秒几千次主线程
/// stat。这里只在任务列表真的发生变化时异步探一遍，结果缓存供卡片读取。
final missingSourceTaskIdsProvider = FutureProvider<Set<String>>((ref) async {
  final tasks = ref.watch(taskListProvider).valueOrNull ?? const <RenewTask>[];
  if (tasks.isEmpty) return const <String>{};
  final probe = ref.read(fileExistsProbeProvider);
  // 同一路径只探一次：同一素材可能被导入成多条任务
  final paths = {for (final task in tasks) task.sourcePath};
  final results = Map.fromEntries(await Future.wait([
    for (final path in paths)
      _probeQuietly(probe, path).then((exists) => MapEntry(path, exists)),
  ]));
  return {
    for (final task in tasks)
      if (results[task.sourcePath] == false) task.id,
  };
});

/// 探测失败（权限不足、外接卷未挂载、路径过长等）不当作「缺失」：
/// 误报会把一条完全正常的任务标成红字并挡住入口，代价比漏报大得多。
/// 但异常不能静默吞掉，仍要落日志。
Future<bool> _probeQuietly(FileExistsProbe probe, String path) async {
  try {
    return await probe(path);
  } catch (e) {
    AppLog.warn('源文件存在性探测失败 $path：$e');
    return true;
  }
}
