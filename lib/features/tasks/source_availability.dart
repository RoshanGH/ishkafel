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

/// 点击进入前的实时校验：返回该任务的源文件此刻是否已不存在。
///
/// [missingSourceTaskIdsProvider] 的缓存只用于「列表上提前打红标」，绝不能
/// 作为拦截判定的唯一依据：它唯一的重算触发是任务列表本身变化，用户在
/// Finder 里删掉源视频后，只要不发生导入/删除/重命名/分析完成，缓存里那条
/// 仍是「存在」——拦截不触发，用户照常进审片台，然后播放器黑屏、两条辅助
/// 轨报失败；反方向（文件放回来了）则是红标不消、入口一直被挡。
///
/// 一次 stat 的成本完全可接受：它只在用户点击时发生一次，不是逐帧。
/// 结果与缓存不一致时顺手让缓存重算，列表上的标记随即跟上。
Future<bool> isSourceMissingNow(WidgetRef ref, RenewTask task) async {
  final probe = ref.read(fileExistsProbeProvider);
  final exists = await _probeQuietly(probe, task.sourcePath);
  final cachedMissing =
      ref.read(missingSourceTaskIdsProvider).valueOrNull ?? const <String>{};
  if (cachedMissing.contains(task.id) == exists) {
    ref.invalidate(missingSourceTaskIdsProvider);
  }
  return !exists;
}

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
