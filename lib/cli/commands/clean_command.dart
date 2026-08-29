import 'dart:io';

import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_artifacts.dart';
import '../cli_output.dart';

/// `ishkafel clean [--yes]`：把盘上没主的东西清掉。
///
/// **Agent 也该能收自己造的东西**：跑久了盘上会攒下几个 G——素材、切片、
/// 抽帧、导出中间产物。「清理残留产物」以前只有界面能点。
///
/// 不给 `--yes` 只报会删什么，不动手——删了没法撤回。
Future<int> runCleanCommand({
  required List<String> rest,
  required Directory dataDir,
  bool confirmed = false,
  StringSink? out,
  StringSink? err,
}) async {
  final artifacts = TaskArtifacts(dataDir);
  final tasks = await FileTaskRepository(dataDir).findAll();
  final live = {for (final t in tasks) t.id};

  final orphans = artifacts.orphans(live);
  final transients = artifacts.transients();
  final retired = artifacts.retired();
  final all = [...orphans, ...transients, ...retired];

  int sizeOf(FileSystemEntity e) {
    try {
      if (e is File) return e.lengthSync();
      if (e is Directory) {
        var n = 0;
        for (final f in e.listSync(recursive: true).whereType<File>()) {
          n += f.lengthSync();
        }
        return n;
      }
    } catch (_) {
      // 量不到就算 0：这只影响报出来的数字，不影响该不该删
    }
    return 0;
  }

  final bytes = all.fold<int>(0, (sum, e) => sum + sizeOf(e));
  final mb = (bytes / 1024 / 1024).round();

  if (all.isEmpty) {
    emitJson({
      'orphanCount': 0,
      'freedMB': 0,
      'next': '没什么可清的',
    }, out: out);
    return 0;
  }

  if (!confirmed) {
    emitJson({
      'orphanCount': orphans.length,
      'transientCount': transients.length,
      'retiredCount': retired.length,
      'willFreeMB': mb,
      'items': [
        for (final e in all.take(20))
          e.path.split('${dataDir.path}/').last,
      ],
      'next': '看着没问题就加 --yes 真删。删了没法撤回，所以默认只报不删',
    }, out: out);
    return 0;
  }

  // delete 返回的是**释放的字节数**，不是条数——字段名写成 removed 的话，
  // 拿到 39485646 会被当成「删了三千九百万个文件」
  final freedBytes = artifacts.delete(all);
  emitJson({
    'ok': true,
    'removedItems': all.length,
    'freedMB': (freedBytes / 1024 / 1024).round(),
    'next': '清完了',
  }, out: out);
  return 0;
}
