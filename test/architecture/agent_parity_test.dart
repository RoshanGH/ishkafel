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

  /// 定位写错，后面写得再细也白搭：Agent 读完开头就形成了「这是个换画面的
  /// 工具」的印象，脚本成片那一半会被当成附属，甚至根本不会想起来用。
  test('手册开篇要把两条线摆成平级，不能只说替换裂变', () {
    final head = agentSkillMarkdown.substring(0, 2200);
    expect(head, contains('替换裂变'));
    expect(head, contains('脚本成片'),
        reason: '开篇只说替换裂变的话，「从台词直接造一条新片」这条线就被埋没了');
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

  /// 一级命令对、**二级子命令写错**同样让人第一次就撞墙——而且更隐蔽，
  /// 因为「命令存在」这道检查照样绿。
  ///
  /// 验收 Agent 撞到的原样：手册新写的两节里是 `apply plan`（单数），
  /// 实际命令是 `apply plans`。它照着跑，退出码 2、「认不出「plan」」。
  test('二级子命令也要真的存在——一级对了不代表能跑', () {
    final subs = <String, Set<String>>{
      'apply': {'plans', 'segment', 'tags'},
      'review': {'list', 'drop', 'keep'},
      'voice': {'generate'},
      'ui': {'new-task', 'tasks'},
    };
    // 这份名单是**手写**的，所以它漏过东西：`script` 压根没进来，
    // 于是手册里那条根本不存在的 `script from-video` 一直没人查。
    // script 现在由 script_subcommands_real_test 从代码里自动抓，
    // 这里剩下的几条哪天也该照做
    for (final entry in subs.entries) {
      for (final m in RegExp('ishkafel ${entry.key} ([a-z][a-z-]*)')
          .allMatches(agentSkillMarkdown)) {
        final sub = m.group(1)!;
        // 「ishkafel voice <任务>」这种直接跟参数的不算子命令
        if (sub.startsWith('<')) continue;
        expect(entry.value, contains(sub),
            reason: '手册里写着 `ishkafel ${entry.key} \$sub`，'
                '但 ${entry.key} 只认 ${entry.value.join(' / ')}。'
                '照着跑第一次就撞墙');
      }
    }
  });

  /// 手册自己用一整段警告「null 不是干净」，给的命令却是
  /// `jq '.burnedText // "画面都干净"'`——`//` 在 jq 里正是
  /// 「null 就用右边这个」。**手册给的命令做的就是它警告不要做的事**。
  ///
  /// 配上「委派路径不报这个字段」，后果是：查出来「画面都干净」，
  /// 而实际上烧着 5 条字。
  test('三态字段不许用 jq 的 // 折叠掉 null', () {
    // 只看真要敲的那些行——注释里举反面例子是允许的（正是在教别这么写）
    final commands = agentSkillMarkdown
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('#'))
        .join('\n');
    for (final field in ['burnedText', 'productBrand']) {
      expect(
        RegExp('\\.$field // "[^"]*干净').hasMatch(commands),
        isFalse,
        reason: '手册用 `.$field // "…干净"` 把「没看成」显示成「干净」——'
            '而这一节整段都在说这两件事不是一回事',
      );
    }
  });

  /// 手册里那几节是带序号的（① ② ③…）。插一节忘了顺延后面的，
  /// 就会出现两个 ⑤——读的人以为漏了一节，或者以为自己看错了。
  test('分节序号不重不漏', () {
    final marks = RegExp(r'^### ([①②③④⑤⑥⑦⑧⑨])', multiLine: true)
        .allMatches(agentSkillMarkdown)
        .map((m) => m.group(1)!)
        .toList();
    expect(marks.toSet().length, marks.length,
        reason: '手册里有重复的分节序号：$marks');
    const order = '①②③④⑤⑥⑦⑧⑨';
    for (var i = 1; i < marks.length; i++) {
      expect(order.indexOf(marks[i]), greaterThan(order.indexOf(marks[i - 1])),
          reason: '分节序号没按顺序：$marks');
    }
  });

  test('会静默毁掉成片的几条自查必须在手册里', () {
    // 这几条都「不拦导出」，所以更危险：片子导得出来，但里面是坏的
    expect(agentSkillMarkdown, contains('stale'),
        reason: '配音过期不拦导出——会混出一条前后两个人说话的片子');
    expect(agentSkillMarkdown, contains('subtitle-too-short'),
        reason: '字幕盖不住语音不拦导出——配音在念、字幕停着不动');
    expect(agentSkillMarkdown, contains('burnedText'),
        reason: '素材画面上本来就烧着字，换上去再烧一行台词字幕就是两层字'
            '——只有看图才发现得了，Agent 必须知道去哪儿看这个信号');
    expect(agentSkillMarkdown, contains('productBrand'),
        reason: '产品露出镜头不能跨品牌换——台词说滴露而画面是若也直播间，'
            '真机上交付过这样一条成片；--exclude-projects 还会放大这个风险');
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
