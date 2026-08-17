import 'dart:io';

import 'package:args/args.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/analyze_command.dart';
import 'package:ishkafel/cli/commands/blank_command.dart';
import 'package:ishkafel/cli/commands/apply_command.dart';
import 'package:ishkafel/cli/commands/candidates_command.dart';
import 'package:ishkafel/cli/commands/export_command.dart';
import 'package:ishkafel/cli/commands/import_command.dart';
import 'package:ishkafel/cli/commands/open_command.dart';
import 'package:ishkafel/cli/commands/review_command.dart';
import 'package:ishkafel/cli/commands/skill_command.dart';
import 'package:ishkafel/cli/commands/task_command.dart';
import 'package:ishkafel/cli/commands/todo_command.dart';
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
    ..addOption('unit', help: '单元下标（从 0 开始）')
    ..addOption('shot', help: '镜头下标（从 0 开始）')
    ..addOption('file', help: 'apply 用：结果文件（不给就从 stdin 读）')
    ..addOption('out', help: 'export 用：输出目录')
    ..addOption('tag-groups', help: 'import 用：标签组 id，逗号分隔')
    ..addFlag('install',
        negatable: false, help: 'skill 用：把说明书装成技能（确定性落盘）')
    ..addOption('dir',
        help: 'skill --install 用：装到指定技能目录（不认默认目录的 Agent 自报）')
    ..addOption('name', help: 'blank create 用：任务名')
    ..addOption('resolution', help: 'export 用：短边 480/720/1080/1440/2160')
    ..addOption('fps', help: 'export 用：24/25/30/50/60')
    ..addOption('bitrate',
        help: 'export 用：recommended/higher/lower 或 kbps 数字')
    ..addOption('codec', help: 'export 用：h264/hevc')
    ..addOption('format', help: 'export 用：mp4/mov')
    ..addOption('tags', help: 'blank tags 用：标签，逗号分隔')
    ..addOption('external',
        help: 'analyze 用：哪几步交给调用方做（segment,tag）')
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
    'import' => await runImportCommand(
        rest: rest,
        dataDir: dataDir,
        tagGroups: parsed['tag-groups'] as String?,
      ),
    'tag-groups' => await runTagGroupsCommand(),
    'analyze' => await runAnalyzeCommand(
        rest: rest,
        dataDir: dataDir,
        external: parsed['external'] as String?,
      ),
    'skill' => await runSkillCommand(
        rest: rest,
        install: parsed['install'] as bool,
        dir: parsed['dir'] as String?,
      ),
    'review' => await runReviewCommand(rest: rest, dataDir: dataDir),
    'blank' => await runBlankCommand(
        rest: rest,
        dataDir: dataDir,
        name: parsed['name'] as String?,
        tagGroups: parsed['tag-groups'] as String?,
        unit: int.tryParse(parsed['unit'] as String? ?? ''),
        tags: parsed['tags'] as String?,
      ),
    'todo' => await runTodoCommand(rest: rest, dataDir: dataDir),
    'task' => await runTaskCommand(rest: rest, dataDir: dataDir),
    'open' => await runOpenCommand(rest: rest, dataDir: dataDir),
    'apply' => await runApplyCommand(
        rest: rest, dataDir: dataDir, file: parsed['file'] as String?),
    'export' => await runExportCommand(
        rest: rest,
        dataDir: dataDir,
        outputDir: parsed['out'] as String?,
        resolution: parsed['resolution'] as String?,
        fps: parsed['fps'] as String?,
        bitrate: parsed['bitrate'] as String?,
        codec: parsed['codec'] as String?,
        format: parsed['format'] as String?,
      ),
    'candidates' => await runCandidatesCommand(
        rest: rest,
        dataDir: dataDir,
        unitIndex: int.tryParse(parsed['unit'] as String? ?? ''),
        shotIndex: int.tryParse(parsed['shot'] as String? ?? ''),
      ),
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
  tag-groups       当前企业下有哪些标签组（import 要用它的 id）
  import <视频> [--tag-groups <id,id>]
                   建任务。**标签组要在这一步定**——它是打标的受控词表，
                   没有它后面挑替换素材时会没有标签可用
  analyze <id> [--external=segment,tag]
                   跑分析。--external 指定哪几步由你来做——那时会停下来
                   输出待办，你做完用 apply 交回来。ASR 不可外包
  apply segment|tags <id> --file <json>
                   回填外部结果
  todo <id>        把当前欠着的那件外包待办再吐一遍（丢了输出时用，不重跑分析）
  skill [--install] [--dir <目录>]
                   给 Agent 的操作手册。--install 装成技能（缺省认
                   Claude Code / Codex 的目录；别家用 --dir 自报），
                   之后在任意文件夹、任意会话都生效
  task <id>        任务全貌（单元、镜头、标签、导出历史）
  candidates <id> --unit <i> [--shot <j>]
                   候选素材与上下文（本单元台词、相邻镜头及其已选素材）
  open <id>        把 app 弹出来并落到这个任务的工作台
  review <id>      把 app 弹出来进**审核模式**：人过一遍你挑的候选、勾选去留。
                   确认后 task <id> 里的方案就是最终结果，等用户发话再继续
  apply plans <id> --file <json>
                   提交完整方案列表（每条都是整体设计过的，不做笛卡尔积）
  export <id> [--out <目录>] [--resolution N] [--fps N]
              [--bitrate recommended|higher|lower|<kbps>]
              [--codec h264|hevc] [--format mp4|mov]
                   按已提交的方案逐条导出。规格缺省 1080/30fps/推荐码率
  blank create --name <名> --tag-groups <id,id>
                   建空白任务（不用原片，从素材拼），自带 4 个空分子
  blank add|remove|tags <id> [--unit i] [--tags a,b]
                   空白任务的分子增删与打标（标签必须在词表内）

通用参数：
${parser.usage}
''';
