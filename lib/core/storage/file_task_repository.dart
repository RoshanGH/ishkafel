import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../log/app_log.dart';
import '../models/renew_task.dart';
import 'task_repository.dart';

/// 装载诊断能力：把「跳过了几个读不出来的任务文件」这一事实上报给上层。
///
/// 只写日志的后果是用户看到的是「我的任务不见了」，甚至是空态引导文案。
/// 做成独立接口而不是塞进 TaskRepository，是为了不影响其他实现与测试替身。
abstract class TaskLoadDiagnostics {
  /// 最近一次 findAll 中被跳过的任务文件数
  int get skippedTaskFileCount;
}

/// JSON 文件实现：每任务一个 `<rootDir>/tasks/<id>.json`
class FileTaskRepository implements TaskRepository, TaskLoadDiagnostics {
  final Directory rootDir;

  int _skippedTaskFileCount = 0;

  FileTaskRepository(this.rootDir);

  /// 仅反映最近一次 findAll 的结果（每次装载重新计数）
  @override
  int get skippedTaskFileCount => _skippedTaskFileCount;

  Directory get _tasksDir => Directory(p.join(rootDir.path, 'tasks'));

  File _fileOf(String id) => File(p.join(_tasksDir.path, '$id.json'));

  @override
  Future<List<RenewTask>> findAll() async {
    _skippedTaskFileCount = 0;
    if (!await _tasksDir.exists()) return const [];
    final tasks = <RenewTask>[];
    await for (final entity in _tasksDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await entity.readAsString());
        tasks.add(RenewTask.fromJson(json as Map<String, dynamic>));
      } on FormatException catch (e) {
        // JSON 格式错误：跳过该文件，不影响其余任务加载
        AppLog.warn('跳过损坏任务文件 ${entity.path}：$e');
        _skippedTaskFileCount++;
      } on TypeError catch (e) {
        // 字段类型不符预期：同样跳过，不吞掉其他类型的异常（如 I/O 错误）
        AppLog.warn('跳过字段类型错误的任务文件 ${entity.path}：$e');
        _skippedTaskFileCount++;
      } on ArgumentError catch (e) {
        // 兜底：未知枚举值已在模型层回退，这里只防御其余参数类异常
        AppLog.warn('跳过参数非法的任务文件 ${entity.path}：$e');
        _skippedTaskFileCount++;
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
      AppLog.warn('读取任务文件失败（格式错误） ${file.path}：$e');
      return null;
    } on TypeError catch (e) {
      // 字段类型不符预期：同样返回 null，不吞掉其他类型的异常（如 I/O 错误）
      AppLog.warn('读取任务文件失败（字段类型错误） ${file.path}：$e');
      return null;
    } on ArgumentError catch (e) {
      // 兜底：未知枚举值已在模型层回退，这里只防御其余参数类异常
      AppLog.warn('读取任务文件失败（参数非法） ${file.path}：$e');
      return null;
    }
  }

  @override
  Future<void> save(RenewTask task) async {
    await _tasksDir.create(recursive: true);
    final target = _fileOf(task.id);
    // 原子写入：先写临时文件，再 rename 覆盖目标，避免写到一半被读到半截内容
    final tmp = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsString(jsonEncode(task.toJson()));
    await tmp.rename(target.path);
  }

  @override
  Future<void> delete(String id) async {
    final file = _fileOf(id);
    if (await file.exists()) await file.delete();
  }
}
