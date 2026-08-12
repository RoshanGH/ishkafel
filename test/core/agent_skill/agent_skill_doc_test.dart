import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/agent_skill/agent_skill_doc.dart';

/// 手册正文是**生成**进二进制的（tool/gen_agent_skill.dart）。
///
/// 生成物一旦和源文件对不上，使用者装到的就是旧手册——Agent 照着旧文档调
/// 新命令，报错还不知道为什么。这条测试就是为了让「改了 md 忘了重新生成」
/// 立刻失败，而不是等包发出去。
void main() {
  test('内嵌的手册和 docs/AGENT_SKILL.md 一字不差', () {
    final source = File('docs/AGENT_SKILL.md').readAsStringSync();
    expect(
      agentSkillMarkdown,
      source,
      reason: '改完 docs/AGENT_SKILL.md 要跑：dart run tool/gen_agent_skill.dart',
    );
  });

  test('手册里必须有全流程那几条命令——少了 Agent 就得靠猜', () {
    for (final command in ['ishkafel import', 'ishkafel analyze',
        'ishkafel candidates', 'ishkafel apply plans', 'ishkafel export']) {
      expect(agentSkillMarkdown, contains(command));
    }
  });
}
