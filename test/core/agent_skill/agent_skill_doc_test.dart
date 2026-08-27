import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/agent_skill/agent_skill_doc.dart';
import 'package:ishkafel/core/agent_skill/skill_installer.dart';

/// 手册正文是**生成**进二进制的（tool/gen_agent_skill.dart）。
///
/// 生成物一旦和源文件对不上，使用者装到的就是旧手册——Agent 照着旧文档调
/// 新命令，报错还不知道为什么。这条测试就是为了让「改了 md 忘了重新生成」
/// 立刻失败，而不是等包发出去。
void main() {
  test('内嵌的手册包含两份来源，一字不差', () {
    final main = File('docs/AGENT_SKILL.md').readAsStringSync().trimRight();
    final script =
        File('docs/agent/SCRIPT_SKILL.md').readAsStringSync().trimRight();
    expect(agentSkillMarkdown, startsWith(main),
        reason: '改完 docs/AGENT_SKILL.md 要跑：dart run tool/gen_agent_skill.dart');
    expect(agentSkillMarkdown, endsWith('\n'));
    expect(agentSkillMarkdown, contains(script),
        reason: '脚本成片那条线必须一起交付——它原来没有任何交付通道，'
            'Agent 装完技能手册里 ishkafel script 一个字都没有');
  });

  /// 技能的 description 决定 Agent **什么时候会想起用它**。
  /// 只写「成片翻新」的话，用户说「帮我做条口播视频」它根本不会联想过来
  test('技能描述要覆盖两类场景，不能只提翻新', () {
    final desc = SkillInstaller.describeForFrontmatter();
    expect(desc, contains('翻新'));
    expect(desc, anyOf(contains('脚本'), contains('口播'), contains('台词')),
        reason: '从台词造新片也是这个工具干的事，描述里不写就等于没有');
  });

  test('脚本成片的命令要在手册里出现——否则那条线对 Agent 不存在', () {
    for (final command in [
      'ishkafel script show',
      'ishkafel script apply',
      'ishkafel script voice',
    ]) {
      expect(agentSkillMarkdown, contains(command), reason: '缺 $command');
    }
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
