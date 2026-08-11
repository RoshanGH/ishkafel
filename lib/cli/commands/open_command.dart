import 'dart:io';

import 'package:path/path.dart' as p;

import '../cli_output.dart';

/// app 的默认安装位置。装在别处时用 `ISHKAFEL_APP` 指定
const String defaultAppPath = '/Applications/ishkafel.app';

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
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel open <任务 id>');
    return exitBadUsage;
  }
  final id = rest.first;
  // 先确认任务在不在：拉起一个空窗口只会让人困惑
  if (!File(p.join(dataDir.path, 'tasks', '$id.json')).existsSync()) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  final appPath =
      (env ?? Platform.environment)['ISHKAFEL_APP'] ?? defaultAppPath;
  final exec = run ?? Process.run;
  final result = await exec('open', ['-a', appPath, '--args', '--task=$id']);
  if (result.exitCode != 0) {
    sink.writeln('打不开 app（$appPath）：${'${result.stderr}'.trim()}');
    return 1;
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
