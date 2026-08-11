import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../cli_output.dart';
import '../plan_submission.dart';

/// `ishkafel apply plans <task> --file <json>`（也支持从 stdin 读）
///
/// 收下 Agent 提交的方案列表，**过校验**之后落盘，供 `export` 使用。
///
/// 校验不过就整批拒绝并一次点全所有问题——让它改一个提交一次是在浪费双方
/// 的时间。外包出去的是「判断」，不是「数据结构的定义权」（spec 第三节）。
Future<int> runApplyCommand({
  required List<String> rest,
  required Directory dataDir,
  String? file,
  String holder = 'agent',
  Future<String> Function()? readStdin,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.length < 2) {
    sink.writeln('用法：ishkafel apply plans <任务 id> --file <方案.json>');
    return exitBadUsage;
  }
  final what = rest.first;
  if (what != 'plans') {
    // segment / tags / shots 是第二期后半段的事，先明确说清楚而不是装作不认识
    sink.writeln('现在只支持 apply plans，收到的是：$what');
    return exitBadUsage;
  }
  final id = rest[1];

  final repository = FileTaskRepository(dataDir);
  final task = await repository.findById(id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }

  // 别人正持着锁就不写——两边同时写会互相覆盖，而且悄无声息
  final lock = TaskLockFile(dataDir: dataDir, taskId: id);
  if (!lock.acquire(holder)) {
    final current = lock.read();
    sink.writeln('${current?.holder ?? '别人'} 正在操作这个任务，写不进去。'
        '等它结束，或在 app 里强制接管');
    return exitLocked;
  }

  final String raw;
  try {
    raw = file == null
        ? await (readStdin ?? _readStdin)()
        : File(file).readAsStringSync();
  } catch (e) {
    sink.writeln('读不到方案文件：$e');
    return exitBadUsage;
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (e) {
    sink.writeln('方案不是合法的 JSON：$e');
    return exitBadUsage;
  }

  final validation = parsePlans(decoded, task);
  if (!validation.ok) {
    for (final problem in validation.errors) {
      sink.writeln('· $problem');
    }
    return exitBadUsage;
  }

  _writePlans(dataDir, id, raw);
  emitJson({
    'ok': true,
    'plans': [
      for (final plan in validation.plans)
        {'name': plan.name, 'units': plan.units.length},
    ],
  }, out: out);
  return 0;
}

/// 方案落在任务目录旁边：`<dataDir>/plans/<taskId>.json`。
///
/// 不塞进任务 JSON：那份是 GUI 也在写的，两边同时改一个文件的不同部分
/// 只会把冲突变复杂。方案是 Agent 这条路独有的产物，单独放。
void _writePlans(Directory dataDir, String taskId, String raw) {
  final file = File(p.join(dataDir.path, 'plans', '$taskId.json'));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(raw);
}

/// 读回已提交的方案；没有就返回 null
String? readSubmittedPlans(Directory dataDir, String taskId) {
  final file = File(p.join(dataDir.path, 'plans', '$taskId.json'));
  return file.existsSync() ? file.readAsStringSync() : null;
}

Future<String> _readStdin() async =>
    await stdin.transform(utf8.decoder).join();
