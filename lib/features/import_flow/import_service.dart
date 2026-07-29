import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/ffmpeg/ffprobe_service.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/models/renew_task.dart';
import '../../core/storage/task_repository.dart';

/// 导入编排：探测元信息 → 创建任务 → 抽封面 → 落库
class ImportService {
  final TaskRepository repository;
  final FfprobeService ffprobe;
  final ThumbnailService thumbnails;
  final Directory coversDir;
  final String Function() idGenerator;
  final DateTime Function() clock;

  ImportService({
    required this.repository,
    required this.ffprobe,
    required this.thumbnails,
    required this.coversDir,
    String Function()? idGenerator,
    DateTime Function()? clock,
  })  : idGenerator = idGenerator ?? _defaultId,
        clock = clock ?? DateTime.now;

  static String _defaultId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Future<RenewTask> importLocalFile(String filePath) async {
    final info = await ffprobe.probe(filePath);
    final id = idGenerator();
    final now = clock();
    await coversDir.create(recursive: true);
    final coverPath = p.join(coversDir.path, '$id.jpg');
    await thumbnails.extractCover(videoPath: filePath, outPath: coverPath);
    final task = RenewTask(
      id: id,
      name: p.basenameWithoutExtension(filePath),
      sourcePath: filePath,
      videoInfo: info,
      coverPath: coverPath,
      status: RenewTaskStatus.analyzing,
      createdAt: now,
      updatedAt: now,
    );
    await repository.save(task);
    return task;
  }
}
