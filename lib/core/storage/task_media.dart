import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';

/// 一个任务用到的**物料**（下载来的素材、配乐）存在哪儿。
///
/// 规矩是**按项目存、不留孤儿**：凡是进了用户方案的东西都落在这个任务
/// 名下，删任务时跟着一起走。
///
/// 此前它们在跨任务共享的 `material_cache/`、`bgm_cache/` 里按素材 id
/// 命名——省了重复下载，代价是**任务删了没人收**：盘上永远躺着一批
/// 不知道归谁的文件，谁都不敢删。同一条素材用在两个片子里现在会存两份，
/// 这是为「删干净」付的价，用户明确选了这一边。
///
/// **路径只此一处算**。此前有 12 个地方各写各的
/// `p.join(dataDir, 'material_cache', '$id.mp4')`，改一个漏一个——
/// 今天已经因为「同一个东西两处算」出过静音和配音过期两个 bug。
class TaskMedia {
  final Directory dataDir;
  final String taskId;

  const TaskMedia({required this.dataDir, required this.taskId});

  /// 目录布局跟 [TaskArtifacts.perTaskDirNames] 一致：`<类目>/<taskId>/`。
  /// 删任务的清理器照着那份清单走，新目录自动被覆盖到
  Directory get materialsDir =>
      Directory(p.join(dataDir.path, 'materials', taskId));

  Directory get bgmDir => Directory(p.join(dataDir.path, 'bgm', taskId));

  /// 预览代理（把素材转成预览链路统一规格的那一份）。
  /// **派生产物**：删了会重转，不会丢东西
  Directory get proxyDir => Directory(p.join(dataDir.path, 'proxy', taskId));

  /// 素材人声分离结果。同样是派生产物，但**重算很贵**（要跑模型，
  /// 分钟级、32MB/条）——所以它跟着任务走而不是随手清
  Directory get vocalsDir =>
      Directory(p.join(dataDir.path, 'vocals', taskId));

  String materialPath(int materialId) =>
      p.join(materialsDir.path, '$materialId.mp4');

  /// 这条素材在本地吗。**按文件是否真的存在判定**——只看路径拼得出来
  /// 就当命中，会静默放出一个空文件或半截下载
  String? localMaterial(int materialId) {
    final f = File(materialPath(materialId));
    return f.existsSync() && f.lengthSync() > 0 ? f.path : null;
  }

  /// 配乐认多种扩展名：曲子不一定是 mp3
  String? localBgm(int materialId) {
    for (final ext in const ['mp3', 'm4a', 'wav', 'aac', 'flac']) {
      final f = File(p.join(bgmDir.path, '$materialId.$ext'));
      if (f.existsSync() && f.lengthSync() > 0) return f.path;
    }
    return null;
  }

  /// 删任务时把这个任务的物料一起收走
  void deleteAll() {
    for (final d in [materialsDir, bgmDir, proxyDir, vocalsDir]) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (e) {
        AppLog.warn('物料目录删除失败（${d.path}）：$e');
      }
    }
  }
}
