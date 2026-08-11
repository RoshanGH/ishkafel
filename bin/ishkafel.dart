import 'dart:io';

import 'package:args/args.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/task_command.dart';
import 'package:ishkafel/cli/data_dir.dart';

/// ishkafel 的命令行入口。
///
/// **存在的理由**：让 Agent（Claude Code / Codex / 任何能跑 bash 的）驱动
/// 全流程——导入、分析、挑素材、配乐、导出，人只看成片；也可以在任意一步
/// 停下来，把 GUI 弹出来转人工。
///
/// **为什么是 CLI 不是 MCP Server**（详见
/// `docs/superpowers/specs/2026-08-11-agent-cli-design.md` 第二节）：
/// - 决定性的一条是**跨平台**：Codex 用不了 MCP，但谁都能跑 bash
/// - 任务是文件存储，CLI 与 GUI 天然读同一份数据，不需要进程间通信
/// - 人能直接跑同一条命令复现问题；MCP 要专门的客户端才能调试
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('json', help: '输出结构化 JSON', defaultsTo: true)
    ..addOption('data-dir', help: '数据目录（默认与 app 一致）')
    ..addFlag('help', abbr: 'h', negatable: false, help: '显示这份用法');

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    failWith('${e.message}\n\n${usageText(parser)}', code: exitBadUsage);
  }

  if (parsed['help'] as bool) {
    stdout.writeln(usageText(parser));
    exit(0);
  }
  if (parsed.rest.isEmpty) {
    failWith('缺少命令。\n\n${usageText(parser)}', code: exitBadUsage);
  }

  final command = parsed.rest.first;
  final rest = parsed.rest.skip(1).toList();

  final Directory dataDir;
  try {
    dataDir = resolveDataDir(override: parsed['data-dir'] as String?);
  } on StateError catch (e) {
    failWith(e.message, code: exitBadUsage);
  }

  final code = switch (command) {
    'task' => await runTaskCommand(rest: rest, dataDir: dataDir),
    _ => failWith('未知命令：$command\n\n${usageText(parser)}', code: exitBadUsage),
  };
  exit(code);
}

/// 用法说明。抽出来是为了让「没给命令」「命令不认识」「-h」三条路
/// 给出同一份文本——三份各写各的迟早会漂
String usageText(ArgParser parser) => '''
ishkafel —— 成片翻新工具的命令行入口

用法：ishkafel <命令> [参数]

命令：
  task <id>        任务全貌（单元、镜头、标签、导出历史）

通用参数：
${parser.usage}
''';
