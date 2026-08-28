import 'dart:io';

/// 把 `docs/AGENT_SKILL.md` + `docs/agent/SCRIPT_SKILL.md` 编成一个 Dart 常量。
///
///   dart run tool/gen_agent_skill.dart
///
/// 为什么要内嵌而不是运行时读文件：这份说明书有两个消费者——GUI 里的
/// 「安装 Agent 说明书」按钮，和 `ishkafel skill` 命令。两者都可能跑在
/// 用户机器上，那里没有仓库。编进二进制就没有「文件找不到」这一类状态，
/// 也保证**说明书的版本永远跟工具的版本一致**：文档一旦散落成副本，工具
/// 升级了、命令变了，副本还停在旧版，Agent 照着旧文档调新命令，报错还
/// 不知道为什么。
///
/// 有测试盯着这个常量和 md 是否一致，改了 md 忘了重新生成会直接失败。
void main() {
  final source = File('docs/AGENT_SKILL.md');
  if (!source.existsSync()) {
    stderr.writeln('找不到 docs/AGENT_SKILL.md');
    exit(1);
  }
  // 脚本成片那条线**必须一起交付**：它的 14 个子命令原来只写在
  // docs/agent/SCRIPT_SKILL.md 里，而那份文件没有任何交付通道——
  // Agent 装完技能，手册里 `ishkafel script` 一个字都没有，
  // 整条线对它等于不存在（真机上就是这个状态）
  final script = File('docs/agent/SCRIPT_SKILL.md');
  if (!script.existsSync()) {
    stderr.writeln('找不到 docs/agent/SCRIPT_SKILL.md');
    exit(1);
  }
  final markdown = '${source.readAsStringSync().trimRight()}\n'
      '\n---\n\n'
      '# 脚本成片（编导台）\n'
      '\n'
      '**另一条线**（与前面的替换裂变平级）：从台词开始造一条新片子，\n'
      '不需要原片。用户想从零做一条、或者看上一条片子想仿着重做时走这里。\n'
      '两条线的命令、数据、界面都是分开的，别混着用。\n'
      '\n'
      '${script.readAsStringSync().trimRight()}\n';
  if (markdown.contains("'''")) {
    // 内嵌用的是 r'''…'''，正文里出现三引号会把字符串截断
    stderr.writeln('AGENT_SKILL.md 里出现了三引号，没法安全内嵌。换个写法。');
    exit(1);
  }

  File('lib/core/agent_skill/agent_skill_doc.dart')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('''
// 这个文件是**生成的**，别手改。
// 改 docs/AGENT_SKILL.md 之后跑：dart run tool/gen_agent_skill.dart
//
// 内嵌的理由见 tool/gen_agent_skill.dart 顶上的注释。

/// 给 Agent 的操作手册正文（来自 docs/AGENT_SKILL.md）
const String agentSkillMarkdown = r\'\'\'
$markdown\'\'\';
''');
  stdout.writeln('生成好了：lib/core/agent_skill/agent_skill_doc.dart'
      '（${markdown.length} 字）');
}
