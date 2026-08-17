import 'dart:io';

import '../../core/agent_skill/agent_skill_doc.dart';
import '../../core/agent_skill/skill_installer.dart';
import '../../core/app_version.dart';
import '../cli_output.dart';

/// `ishkafel skill [--install]`
///
/// 把给 Agent 的操作手册交出来。**手册编在二进制里**，所以它永远和这个版本
/// 的命令对得上——文档一旦散落成副本，工具升级了、命令变了，副本还停在旧版。
///
/// 两种用法：
/// - `ishkafel skill`：打印正文。管道到哪儿是调用方的事
/// - `ishkafel skill --install`：装进各家 Agent 的用户级技能目录，之后在
///   任意文件夹都生效（GUI 里那个按钮做的是同一件事）
Future<int> runSkillCommand({
  required List<String> rest,
  bool install = false,
  String? dir,
  String? home,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  final stdoutSink = out ?? stdout;

  if (rest.isNotEmpty) {
    sink.writeln('用法：ishkafel skill [--install] [--dir <技能目录>]');
    return exitBadUsage;
  }

  if (!install) {
    stdoutSink.write(agentSkillMarkdown);
    return 0;
  }

  // --dir：不认默认目录的 Agent（Cursor、Warp、各家新工具）自报家门。
  // 装到哪它自己最清楚，我们只负责确定性落盘
  final installer = dir != null
      ? SkillInstaller(
          markdown: agentSkillMarkdown,
          version: appVersion,
          targets: [SkillTarget(agent: '自定义', dir: Directory(dir))],
        )
      : SkillInstaller.forCurrentUser(
          markdown: agentSkillMarkdown, version: appVersion, home: home);
  final result = await installer.install();
  (result.ok ? stdoutSink : sink).writeln(result.message);
  return result.ok ? 0 : 1;
}
