import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/agent_skill/agent_skill_doc.dart';

/// 手册里写着 `ishkafel script from-video <参考片>`，而 script 根本没有
/// 这个子命令——真名是 `extract`。
///
/// 已有的「二级子命令也要真的存在」那条测试拦不住它：那份子命令白名单是
/// **手写**的，而 `script` 压根不在名单里。于是这一条从写进手册那天起
/// 就没人查过。
///
/// 后果不是「多敲一次」。验收 Agent 照着手册敲，拿到「未知命令」，
/// 它合理地推断成**环境坏了 / 版本不对**——于是重装 CLI、删任务、
/// 重建任务，整轮白干，还删掉了已经花钱配过音的任务。
/// 一条写错的命令，代价是一整轮。
///
/// 所以名单从**代码里抓**，不手写：以后加子命令、改名字，这里自动跟上。
void main() {
  Set<String> realSubcommands() {
    final src =
        File('lib/cli/commands/script_command.dart').readAsStringSync();
    // 分发就是一串 case '<子命令>':
    final body = src.substring(src.indexOf('switch'));
    return {
      for (final m in RegExp(r"case '([a-z][a-z-]*)':").allMatches(body))
        m.group(1)!,
    };
  }

  test('手册里每条 `ishkafel script X` 都要真的能敲', () {
    final real = realSubcommands();
    expect(real, contains('extract'), reason: '抓不到子命令的话这条测试就是空转');

    // **两种写法都要抓**：正文里是 `ishkafel script extract`，
    // 而表格、行内代码里常省掉前缀写成 `script from-video`。
    // 现有检查全都假设有 `ishkafel` 前缀，于是表格里那条错命令
    // 从写下那天起就没被查过——它正是这么溜进去的
    final used = <String>{};
    for (final re in [
      RegExp(r'ishkafel script ([a-z][a-z-]*)'),
      RegExp(r'`script ([a-z][a-z-]*)'),
    ]) {
      for (final m in re.allMatches(agentSkillMarkdown)) {
        used.add(m.group(1)!);
      }
    }
    for (final sub in used) {
      expect(real, contains(sub),
          reason: '手册里写着 `ishkafel script $sub`，而 script 只认 '
              '${(real.toList()..sort()).join(' / ')}。'
              '照着跑拿到的是「未知命令」，人会以为是装坏了');
    }
  });

  test('脚本成片的两个起点都要指向真命令', () {
    // 有参考片走 extract、没有走 new——这两句是整条线的入口，
    // 写错一个字，那半条线就没人走得进去
    for (final cmd in ['script new', 'script extract']) {
      expect(agentSkillMarkdown, contains(cmd),
          reason: '手册没告诉人怎么开始：缺 `$cmd`');
    }
  });
}
