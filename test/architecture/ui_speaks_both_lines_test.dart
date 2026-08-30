import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 手册早就把两条线摆成平级了（见 agent_parity_test），**界面上的介绍
/// 却还停在只有替换裂变的时代**。
///
/// 这件事对拿到包的人影响最直接：他打开设置看「这个工具做什么」，
/// 读到的是「导入一条成片 → 换画面」，于是整条脚本成片在他眼里不存在
/// ——软件有这个能力，他不知道，等于没有。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('「这个工具做什么」要把两条线都说到', () {
    final about = read('lib/features/settings/sections/about_section.dart');
    for (final line in {
      '替换裂变': '拿一条现成的片子换画面',
      '脚本成片': '从台词开始造一条新片，不需要原片',
    }.entries) {
      expect(about, contains(line.key),
          reason: '关于页没提「${line.key}」（${line.value}）——'
              '这是打开包第一眼看到的介绍，漏掉一条线等于那条线不存在');
    }
  });

  test('Agent 说明书那张卡不能只说替换裂变', () {
    final card = read('lib/features/settings/agent_skill_card.dart');
    expect(card, contains('脚本成片'),
        reason: '手册本身两条线都写了，卡片上却说这是「做替换裂变的手册」'
            '——人会以为脚本成片得自己动手，不会想到交给 Agent');
  });

  test('给用户指路不能指到源码目录', () {
    final cli = read('lib/features/settings/cli_install_card.dart');
    expect(cli, isNot(contains('docs/AGENT_SKILL.md')),
        reason: '拿到 zip 的人机器上没有 docs/ 目录。手册就在下面那张卡片里，'
            '指过去就行');
  });
}
