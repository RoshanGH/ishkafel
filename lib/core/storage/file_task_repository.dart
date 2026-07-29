import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
      } on FormatException catch (e) {
        // JSON 格式错误：跳过该文件，不影响其余任务加载
        debugPrint('跳过格式错误的任务文件 ${entity.path}：$e');
        continue;
      } on TypeError catch (e) {
        // 字段类型不符预期：同样跳过，不吞掉其他类型的异常（如 I/O 错误）
        debugPrint('跳过字段类型错误的任务文件 ${entity.path}：$e');
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
    try {
      final json = jsonDecode(await file.readAsString());
      return RenewTask.fromJson(json as Map<String, dynamic>);
    } on FormatException catch (e) {
      // JSON 格式错误：文件损坏返回 null，语义与 findAll 的跳过一致
      debugPrint('读取任务文件失败（格式错误） ${file.path}：$e');
      return null;
    } on TypeError catch (e) {
      // 字段类型不符预期：同样返回 null，不吞掉其他类型的异常（如 I/O 错误）
      debugPrint('读取任务文件失败（字段类型错误） ${file.path}：$e');
      return null;
    }
  }

  @override
  Future<void> save(RenewTask task) async {
    await _tasksDir.create(recursive: true);
    final target = _fileOf(task.id);
    // 原子写入：先写临时文件，再 rename 覆盖目标，避免写到一半被读到半截内容
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(task.toJson()));
    await tmp.rename(target.path);
  }

  @override
  Future<void> delete(String id) async {
    final file = _fileOf(id);
    if (await file.exists()) await file.delete();
  }
}
