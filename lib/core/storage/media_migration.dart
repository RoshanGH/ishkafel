import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import '../models/renew_task.dart';
import 'file_task_repository.dart';
import 'task_media.dart';

/// 迁移结果，给日志和「设置 → 存储」用
class MediaMigrationResult {
  /// 搬到任务名下的文件数
  final int moved;

  /// 没有任何任务引用、直接清掉的孤儿数
  final int orphansRemoved;

  /// 清出来的空间（字节）
  final int freedBytes;

  /// 清掉的老派生缓存字节数（预览代理、人声分离）。**要如实回报**：
  /// 它们会自动重算，但重算要花时间——尤其人声分离是分钟级的
  final int derivedCleared;

  const MediaMigrationResult({
    this.moved = 0,
    this.orphansRemoved = 0,
    this.freedBytes = 0,
    this.derivedCleared = 0,
  });

  bool get didSomething =>
      moved > 0 || orphansRemoved > 0 || derivedCleared > 0;
}

/// 把共享缓存（`material_cache/`、`bgm_cache/`）里的物料**分发到各任务
/// 名下**，然后收掉共享目录。
///
/// 为什么必须做：物料改成按任务存之后，老的共享目录立刻变成一堆没人认领
/// 的文件——正是这次要消灭的东西。不迁就是把孤儿从「设计上的」变成
/// 「历史遗留的」，一样没人敢删。
///
/// 三条保命规矩：
/// - **不覆盖已经在目标位置的文件**：上一次迁到一半被杀（磁盘满、进程被
///   kill），重来时那些已经搬好的是好的，半截文件不能盖掉它们
/// - **0 字节不搬**：那是半截下载，搬过去只会让「文件存在」误判成命中
/// - **共用的素材各存一份**：两个任务用同一条素材，一个 move、其余 copy。
///   同一条素材存两份是「删得干净」的代价，用户明确选了这一边
Future<MediaMigrationResult> migrateSharedMediaToTasks(
    Directory dataDir) async {
  final materialCache = Directory(p.join(dataDir.path, 'material_cache'));
  final bgmCache = Directory(p.join(dataDir.path, 'bgm_cache'));
  final hasDerived = Directory(p.join(dataDir.path, 'preview_proxy'))
          .existsSync() ||
      Directory(p.join(dataDir.path, 'material_vocals')).existsSync();
  if (!materialCache.existsSync() && !bgmCache.existsSync() && !hasDerived) {
    return const MediaMigrationResult();
  }

  final List<RenewTask> tasks;
  try {
    tasks = await FileTaskRepository(dataDir).findAll();
  } catch (e) {
    // 读不到任务清单就**什么都别删**：宁可留着共享目录下次再迁，
    // 也不能把用户的素材当孤儿清掉
    AppLog.warn('物料迁移中止（读不到任务列表）：$e');
    return const MediaMigrationResult();
  }

  // 素材 id → 用到它的任务们
  final materialUsers = <int, Set<String>>{};
  final bgmUsers = <int, Set<String>>{};
  for (final task in tasks) {
    for (final id in _materialIdsOf(task)) {
      (materialUsers[id] ??= {}).add(task.id);
    }
    for (final id in _bgmIdsOf(task)) {
      (bgmUsers[id] ??= {}).add(task.id);
    }
  }

  var moved = 0;
  var orphans = 0;
  var freed = 0;

  ({int moved, int orphans, int freed}) sweep(
    Directory cache,
    Map<int, Set<String>> users,
    String Function(TaskMedia media, String fileName) targetOf,
    Directory Function(TaskMedia media) dirOf,
  ) {
    if (!cache.existsSync()) return (moved: 0, orphans: 0, freed: 0);
    var m = 0, o = 0, f = 0;
    for (final entity in cache.listSync()) {
      if (entity is! File) continue;
      final id = int.tryParse(p.basenameWithoutExtension(entity.path));
      final owners = id == null ? null : users[id];
      final size = _sizeOf(entity);
      // 没人引用 / 认不出编号 / 半截下载：都是孤儿，清掉
      if (owners == null || owners.isEmpty || size == 0) {
        try {
          entity.deleteSync();
          o++;
          f += size;
        } catch (e) {
          AppLog.warn('孤儿物料删除失败（${entity.path}）：$e');
        }
        continue;
      }
      final name = p.basename(entity.path);
      // **一律先 copy、最后才删源**。先 rename 给第一个任务的话，
      // 源文件当场就没了，第二个任务无从复制——两个任务共用一条素材时
      // 后者会拿到空目录（这条是写完第一版就撞上的）
      var distributed = 0;
      for (final taskId in owners) {
        final media = TaskMedia(dataDir: dataDir, taskId: taskId);
        final target = File(targetOf(media, name));
        try {
          if (target.existsSync() && _sizeOf(target) > 0) {
            distributed++; // 已经在了，别覆盖
            continue;
          }
          dirOf(media).createSync(recursive: true);
          entity.copySync(target.path);
          distributed++;
          m++;
        } catch (e) {
          AppLog.warn('物料迁移失败（${entity.path} → ${target.path}）：$e');
        }
      }
      // 每个 owner 都拿到了才删源。有一个没成功就留着，下次启动重来——
      // 宁可多占一份空间，也不能把用户的素材弄丢
      if (distributed == owners.length) {
        try {
          entity.deleteSync();
        } catch (e) {
          AppLog.warn('迁移后源文件删除失败（${entity.path}）：$e');
        }
      }
    }
    return (moved: m, orphans: o, freed: f);
  }

  final a = sweep(
    materialCache,
    materialUsers,
    (media, name) => p.join(media.materialsDir.path, name),
    (media) => media.materialsDir,
  );
  final b = sweep(
    bgmCache,
    bgmUsers,
    (media, name) => p.join(media.bgmDir.path, name),
    (media) => media.bgmDir,
  );
  moved = a.moved + b.moved;
  orphans = a.orphans + b.orphans;
  freed = a.freed + b.freed;

  // 老的派生缓存**整个清掉**。
  //
  // 它们按内容指纹命名（`proxy_<hash>.mp4`），反查不出归谁——没法像素材
  // 那样按引用分发。而它们是算得出来的：预览代理会重转、人声分离会重跑。
  // 留着才是孤儿：新版本按任务存，这两个目录从此没有任何人会去读它
  var derived = 0;
  for (final name in const ['preview_proxy', 'material_vocals']) {
    final d = Directory(p.join(dataDir.path, name));
    if (!d.existsSync()) continue;
    try {
      derived += _dirSize(d);
      d.deleteSync(recursive: true);
    } catch (e) {
      AppLog.warn('老派生缓存清理失败（${d.path}）：$e');
    }
  }

  // 收掉空的共享目录：留着的话，下次谁手滑往里写又会长出一批孤儿
  for (final d in [materialCache, bgmCache]) {
    try {
      if (d.existsSync() && d.listSync().isEmpty) d.deleteSync();
    } catch (e) {
      AppLog.warn('共享物料目录删除失败（${d.path}）：$e');
    }
  }

  if (moved > 0 || orphans > 0) {
    AppLog.info('物料迁移完成：搬 $moved 个到任务名下，清掉 $orphans 个孤儿');
  }
  return MediaMigrationResult(
      moved: moved,
      orphansRemoved: orphans,
      freedBytes: freed,
      derivedCleared: derived);
}

int _dirSize(Directory d) {
  var n = 0;
  try {
    for (final e in d.listSync(recursive: true)) {
      if (e is File) n += _sizeOf(e);
    }
  } catch (_) {}
  return n;
}

int _sizeOf(File f) {
  try {
    return f.lengthSync();
  } catch (_) {
    return 0;
  }
}

/// 这个任务引用了哪些素材。**两条线都要算**：替换裂变走 replacements，
/// 脚本成片走 script.lines[].shots。漏一条就会把在用的素材当孤儿删掉
Set<int> _materialIdsOf(RenewTask task) {
  final ids = <int>{};
  for (final r in task.replacements ?? const []) {
    ids.addAll(r.wholeCandidateIds);
    for (final list in r.shotCandidateIds.values) {
      ids.addAll(list);
    }
  }
  for (final m in task.pickedMaterials) {
    ids.add(m.id);
  }
  for (final line in task.script?.lines ?? const []) {
    for (final shot in line.shots) {
      ids.add(shot.materialId);
    }
  }
  return ids;
}

Set<int> _bgmIdsOf(RenewTask task) {
  final ids = <int>{
    // 脚本成片：一段一首
    for (final seg in task.script?.bgmSegments ?? const []) seg.material.id,
  };
  // 替换裂变：**一段可以选好几首互为备选**，导出时按变体轮流取。
  // 只算 previewIndex 那一首的话，其余备选会被当孤儿删掉，
  // 导第二条变体时就没曲子了
  for (final seg in task.bgm?.segments ?? const []) {
    for (final m in seg.materials) {
      ids.add(m.id);
    }
  }
  return ids;
}
