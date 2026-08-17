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

  test('自举段必须是「跑命令装」——落盘由软件保证，不靠 Agent 自觉存文件', () {
    final head = agentSkillMarkdown.substring(0, 900);
    expect(head, contains('ishkafel skill --install'));
    expect(head, contains('--dir'), reason: '不认默认目录的 Agent 要有自报出口');
    expect(head, contains('回复给用户'), reason: '装到哪要回报，人才能验收');
  });

  test('手册里必须有全流程那几条命令——少了 Agent 就得靠猜', () {
    for (final command in ['ishkafel import', 'ishkafel analyze',
        'ishkafel candidates', 'ishkafel apply plans', 'ishkafel export']) {
      expect(agentSkillMarkdown, contains(command));
    }
  });
}
