import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/log/app_log.dart';

/// 任务中间产物清理接口（与 TaskRepository 同款：抽象接口 + 文件实现，便于测试替身）
abstract class TaskArtifactCleaner {
  Future<void> cleanup(String taskId);
}

/// 文件系统实现：删除任务时连带清理封面与分析工作目录里的产物。
///
/// 不清理的后果：一条 5 分钟素材的 PCM 约 20MB，加上抽帧 JPEG，磁盘只增不减。
class FileTaskArtifactCleaner implements TaskArtifactCleaner {
  final Directory coversDir;
  final Directory workDir;

  const FileTaskArtifactCleaner(
      {required this.coversDir, required this.workDir});

  /// 删除 `covers/<taskId>.jpg` 与 `analysis_work/` 下属于该任务的中间产物。
  ///
  /// 归属判定按「文件名等于 id」或「以 `id.` / `id_` 开头」，避免 id 为前缀的
  /// 其他任务（如 id=ab 与 abc.pcm）被误删。
  @override
  Future<void> cleanup(String taskId) async {
    await _deleteIfExists(File(p.join(coversDir.path, '$taskId.jpg')));
    await _cleanWorkDir(taskId);
  }

  Future<void> _cleanWorkDir(String taskId) async {
    if (!await workDir.exists()) return;
    await for (final entity in workDir.list()) {
      if (entity is! File) continue;
      if (!_belongsTo(p.basename(entity.path), taskId)) continue;
      await _deleteIfExists(entity);
    }
  }

  static bool _belongsTo(String fileName, String taskId) =>
      fileName == taskId ||
      fileName.startsWith('$taskId.') ||
      fileName.startsWith('${taskId}_');

  /// 单个文件删除失败（权限/占用）只记录日志，不影响其余产物与任务删除本身
  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      AppLog.warn('清理中间产物失败 ${file.path}：$e');
    }
  }
}
