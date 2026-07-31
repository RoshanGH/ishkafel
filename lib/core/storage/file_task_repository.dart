import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
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

/// 一次批量装载的产物：任务列表 + 跳过计数 + 待输出的告警文案。
///
/// 告警不在后台 isolate 里直接写日志：`AppLog.sink` 是 static 字段，后台
/// isolate 拿到的是一份全新的默认实现，主 isolate 替换过的出口（真机文件
/// 日志、测试捕获）都收不到。统一带回主 isolate 再输出，保证「错误不被
/// 静默吞掉」这条约束在跨 isolate 之后依然成立。
class TaskLoadPayload {
  final List<RenewTask> tasks;
  final int skippedTaskFileCount;
  final List<String> warnings;

  const TaskLoadPayload({
    required this.tasks,
    required this.skippedTaskFileCount,
    required this.warnings,
  });
}

/// 后台 isolate 入口：遍历任务目录，读盘 + jsonDecode + 重建 RenewTask。
///
/// 必须是顶层函数（`compute` 的约束）。单个任务文件解析失败只跳过该文件并
/// 计数，不让一个坏文件带崩整批；I/O 类异常不在这里吞掉，直接抛出由主
/// isolate 的调用方处理。
Future<TaskLoadPayload> decodeTasksDirectory(String tasksDirPath) async {
  final tasks = <RenewTask>[];
  final warnings = <String>[];
  var skipped = 0;
  await for (final entity in Directory(tasksDirPath).list()) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    try {
      final json = jsonDecode(await entity.readAsString());
      tasks.add(RenewTask.fromJson(json as Map<String, dynamic>));
    } on FormatException catch (e) {
      // JSON 格式错误：跳过该文件，不影响其余任务加载
      warnings.add('跳过损坏任务文件 ${entity.path}：$e');
      skipped++;
    } on TypeError catch (e) {
      // 字段类型不符预期：同样跳过，不吞掉其他类型的异常（如 I/O 错误）
      warnings.add('跳过字段类型错误的任务文件 ${entity.path}：$e');
      skipped++;
    } on ArgumentError catch (e) {
      // 兜底：未知枚举值已在模型层回退，这里只防御其余参数类异常
      warnings.add('跳过参数非法的任务文件 ${entity.path}：$e');
      skipped++;
    }
  }
  tasks.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return TaskLoadPayload(
    tasks: tasks,
    skippedTaskFileCount: skipped,
    warnings: warnings,
  );
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

  /// 批量装载：整批「读盘 + 解码 + 建对象」搬到后台 isolate。
  ///
  /// 留在 UI isolate 时，每条任务约 1 ms 的同步解码（96 秒素材、44 KB JSON）
  /// 会跟渲染抢时间片：实测 100 条任务在「用户正在滚动」的负载下，装载耗时
  /// 从 131 ms 涨到 573 ms。`compute` 热身后的固定开销仅 0.10 ms、冷启动
  /// 3.1 ms，即使只有 1 条任务也不比原来慢，因此不设条数阈值。
  @override
  Future<List<RenewTask>> findAll() async {
    _skippedTaskFileCount = 0;
    if (!await _tasksDir.exists()) return const [];
    final payload = await compute(decodeTasksDirectory, _tasksDir.path);
    for (final warning in payload.warnings) {
      AppLog.warn(warning);
    }
    _skippedTaskFileCount = payload.skippedTaskFileCount;
    return List.unmodifiable(payload.tasks);
  }

  /// 单条读取保持在当前 isolate：只解一个文件（实测约 2 ms），跨 isolate
  /// 往返换不来收益，而且调用点（重试分析、失败落库）本就不在渲染热路径上。
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
