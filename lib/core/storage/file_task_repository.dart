import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/renew_task.dart';
import 'task_repository.dart';

/// JSON 文件实现：每任务一个 `<rootDir>/tasks/<id>.json`
class FileTaskRepository implements TaskRepository {
  final Directory rootDir;

  FileTaskRepository(this.rootDir);

  Directory get _tasksDir => Directory(p.join(rootDir.path, 'tasks'));

  File _fileOf(String id) => File(p.join(_tasksDir.path, '$id.json'));

  @override
  Future<List<RenewTask>> findAll() async {
    if (!await _tasksDir.exists()) return const [];
    final tasks = <RenewTask>[];
    await for (final entity in _tasksDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await entity.readAsString());
        tasks.add(RenewTask.fromJson(json as Map<String, dynamic>));
      } on FormatException {
        // 损坏文件跳过，不影响其余任务加载
        continue;
      }
    }
    tasks.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(tasks);
  }

  @override
  Future<RenewTask?> findById(String id) async {
    final file = _fileOf(id);
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    return RenewTask.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<void> save(RenewTask task) async {
    await _tasksDir.create(recursive: true);
    await _fileOf(task.id).writeAsString(jsonEncode(task.toJson()));
  }

  @override
  Future<void> delete(String id) async {
    final file = _fileOf(id);
    if (await file.exists()) await file.delete();
  }
}
