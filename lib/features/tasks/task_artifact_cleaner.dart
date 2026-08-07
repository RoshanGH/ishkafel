import 'dart:io';

import '../../core/log/app_log.dart';
import '../../core/storage/task_artifacts.dart';

/// 任务中间产物清理接口（与 TaskRepository 同款：抽象接口 + 文件实现，便于测试替身）
abstract class TaskArtifactCleaner {
  Future<void> cleanup(String taskId);
}

/// 文件系统实现：删除任务时把它在盘上留下的东西一次清干净。
///
/// 清单只有一份，在 [TaskArtifacts]——此前这里自己维护了一份「封面 +
/// analysis_work 顶层文件」的清单，于是人声分离结果（32M/条）、抽帧目录、
/// 预览切片（几十上百兆）全都删不掉。真机上 1.4G 数据里只有一条活着的任务。
class FileTaskArtifactCleaner implements TaskArtifactCleaner {
  final Directory dataDir;

  const FileTaskArtifactCleaner({required this.dataDir});

  @override
  Future<void> cleanup(String taskId) async {
    final artifacts = TaskArtifacts(dataDir);
    final freed = artifacts.delete(artifacts.of(taskId));
    if (freed > 0) {
      AppLog.info('删除任务 $taskId：清理中间产物 $freed 字节');
    }
  }
}
