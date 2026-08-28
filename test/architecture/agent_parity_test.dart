import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/script_apply_command.dart';
import 'package:ishkafel/cli/top_level_commands.dart';
import 'package:ishkafel/core/agent_skill/agent_skill_doc.dart';

/// **人能干的，Agent 都要能干。**
///
/// 这条原则一直靠人记得，于是漏了三次：
/// - 三轨混音台、本片基调、剪映做完了，Agent 侧空着（0.1.60 才补）
/// - 脚本成片整条线的手册根本没有交付通道，Agent 装完技能看不到
///   `ishkafel script`（同上）
/// - 划词建镜做完了，Agent 读不到词区间、也提交不了（0.1.67 才补）
///
/// 所以把它变成测试：新增一类 apply 而忘了写手册，这里当场红。
/// 拦不住「功能做了但没做 CLI」，但拦得住「做了 CLI 却没人知道」——
/// 后者恰恰是三次里的两次。
void main() {
  test('每一类 apply 都要在手册里出现——写不进手册等于没做', () {
    for (final what in scriptApplyKinds) {
      expect(agentSkillMarkdown, contains('apply $what'),
          reason: '新增了 apply $what 却没写进 docs/agent/SCRIPT_SKILL.md。'
              'Agent 看不到的能力等于不存在');
    }
  });

  test('划词建镜这条线在手册里说得完整', () {
    for (final key in const [
      'startWord',
      'endWord',
      'takenWords',
      'word-shots',
    ]) {
      expect(agentSkillMarkdown, contains(key), reason: '手册里缺 $key');
    }
  });

  /// 定位写错，后面写得再细也白搭：Agent 读完开头就形成了「这是个翻新
  /// 工具」的印象，脚本成片那一半会被当成附属，甚至根本不会想起来用。
  test('手册开篇要把两条线摆成平级，不能只说翻新', () {
    final head = agentSkillMarkdown.substring(0, 2200);
    expect(head, contains('成片翻新'));
    expect(head, contains('脚本成片'),
        reason: '开篇只说翻新的话，「从台词直接造一条新片」这条线就被埋没了');
    expect(head, anyOf(contains('哪条线'), contains('走哪条')),
        reason: 'Agent 拿到需求第一件事是选线，得先告诉它怎么选');
  });

  /// 手册里写了 `ishkafel voices`，而这条命令一直不存在。验收 Agent 撞上：
  /// 手册说「别自己挑音色，用 voices 列给人看」，它照做，拿到「未知命令」
  /// ——既不能挑也不能列，整条配音链路在纯 CLI 下是死的。
  ///
  /// **手册写了的命令必须真的有**。照着不存在的命令走，Agent 会以为是
  /// 环境坏了，而不是文档错了
  test('手册里提到的每条顶层命令都要真的存在', () {
    final declared = <String>{};
    for (final m in RegExp(r'ishkafel ([a-z][a-z-]+)')
        .allMatches(agentSkillMarkdown)) {
      declared.add(m.group(1)!);
    }
    // 这些是参数或说明里的词，不是命令
    declared.removeAll(const {'skill', 'script'});
    for (final c in declared) {
      expect(topLevelCommands, contains(c),
          reason: '手册里写着 `ishkafel $c`，但它不是一条真命令');
    }
  });

  test('会静默毁掉成片的两条自查必须在手册里', () {
    // 这两条都「不拦导出」，所以更危险：片子导得出来，但里面是坏的
    expect(agentSkillMarkdown, contains('stale'),
        reason: '配音过期不拦导出——会混出一条前后两个人说话的片子');
    expect(agentSkillMarkdown, contains('subtitle-too-short'),
        reason: '字幕盖不住语音不拦导出——配音在念、字幕停着不动');
  });

  /// 这份清单和 bin 里的分发是**同一个东西的两处写法**——加了新命令只改一处，
  /// 清单就悄悄落后，而它正是用来盯手册的那把尺子。尺子本身不准，
  /// 手册写错了也照样绿。
  test('命令清单要和真正的分发对得上', () {
    final source = File('bin/ishkafel.dart').readAsStringSync();
    final dispatched = RegExp(r"^\s*'([a-z][a-z-]+)' =>", multiLine: true)
        .allMatches(source)
        .map((m) => m.group(1)!)
        .toSet();

    expect(dispatched, isNotEmpty, reason: '没扫到任何命令，正则该修了');
    expect(dispatched.difference(topLevelCommands.toSet()), isEmpty,
        reason: 'bin 里分发了但清单里没有——手册写它也不会被查');
    expect(topLevelCommands.toSet().difference(dispatched), isEmpty,
        reason: '清单里有但 bin 不认——Agent 照着敲会拿到「未知命令」');
  });

}
