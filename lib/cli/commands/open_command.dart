import 'dart:io';

import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../../core/storage/ui_wake.dart';
import '../app_locator.dart';
import '../cli_output.dart';

/// app 的默认安装位置。装在别处时用 `ISHKAFEL_APP` 指定
/// app 的默认位置。**真正的定位逻辑在 [resolveAppPath]**——
/// 它会先看环境变量，再从 CLI 自己所在的包推，最后才退到这里
export '../app_locator.dart' show defaultAppPath;

/// `ishkafel open <task>` —— 把 GUI 弹出来并落到这个任务的工作台。
///
/// 这是「Agent 做到某一步、让我审核」的落地方式。GUI 和 CLI 读同一份任务
/// 数据，所以**不需要任何进程间通信**——把 app 拉起来、告诉它开哪个任务
/// 就够了。这也是当初选文件存储 + CLI 而不是 MCP Server 白捡的好处。
Future<int> runOpenCommand({
  required List<String> rest,
  required Directory dataDir,
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,

  /// 测试注入：app 在不在。真机走默认（看目录存不存在）
  bool Function(String path)? appExists,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel open <任务 id>');
    return exitBadUsage;
  }
  // 先确认任务在不在（顺带把 #12 这类短编号解析成真实 id）：
  // 拉起一个空窗口只会让人困惑
  final task = await resolveTaskRef(FileTaskRepository(dataDir), rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  // 意图走唤醒文件，不走 --args：启动参数只在冷启动时生效，app 已经在跑
  // 时会被静默丢弃（真机撞到过：再次 open/review 只是把窗口调到前台，
  // 什么都不发生）。文件冷热启动一条路，GUI 轮询读到即删
  writeUiWake(dataDir, task.id, review: false);
  final failure =
      await launchApp(run: run ?? Process.run, env: env, exists: appExists);
  if (failure != null) {
    sink.writeln(failure);
    return exitEnv;
  }
  return 0;
}

/// 启动参数里要直接打开哪个任务（`--task=<id>`）。
///
/// 放在这里而不是 main.dart：它是 `open` 命令的另一半——CLI 写、GUI 读，
/// 两边对同一个约定，摆在一起才不会各改各的。认不出来时返回 null，
/// GUI 照常进列表页。
String? initialTaskIdFrom(List<String> args) {
  const prefix = '--task=';
  for (final arg in args) {
    if (!arg.startsWith(prefix)) continue;
    final id = arg.substring(prefix.length).trim();
    if (id.isNotEmpty) return id;
  }
  return null;
}
