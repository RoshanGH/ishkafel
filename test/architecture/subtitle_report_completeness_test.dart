import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 报告里出现的每个字段名，`subtitle_view.dart` 里必须真有对应产出；
/// 手册里写的每条 `ishkafel subtitle X` 都要真能敲。
///
/// **两条都从代码/手册里现抓真名，不手写白名单。**
///
/// 第一版这里写过一份手写的 12 个字段的清单——评审揪出来：那份清单
/// 从头到尾没碰过 `skill`（手册正文），只是拿一份写死的字符串去
/// `subtitle_view.dart` 里找子串。手册正文里 `framesUnavailable` /
/// `caption` / `maxCharsPerScreen` / `willWrap` / `burned` 一次都没按
/// 字面出现过，这条测试却照样绿——它检查的东西和它自己注释里宣称检查
/// 的东西（「手册里提到的字段」）根本对不上。手写的名单在这个项目已经
/// 漏过 `script` 一整条线，这是同一个坑换个地方又踩了一次。
///
/// 现在改成**真的读手册**：字幕那一节里，凡是写成 `` `.字段名` `` 这种
/// jq 路径的（跟手册里 `subtitleCoverage.note` 是同一个约定），才算
/// 「手册在断言这是一个真实字段」——纯英文单词的反引号（比如 `` `check` ``
/// 这个子命令名、`` `base` `` 这个枚举值、`` `productBrand` `` 这个
/// 跨模块字段）不会被当成字幕报告字段去核对，省得望文生义地误报。
void main() {
  final view = File('lib/cli/subtitle_view.dart').readAsStringSync();
  final skill = File('docs/AGENT_SKILL.md').readAsStringSync();
  final command =
      File('lib/cli/commands/subtitle_command.dart').readAsStringSync();

  /// 拿手册里「字幕：最后几步才动它」那一节的正文——只在这一节里找字段，
  /// 不满篇扫，省得跟别的模块（比如 `candidates` 那节的 `burnedText`）
  /// 的用词混在一起
  String subtitleSection() {
    final start = skill.indexOf('## 字幕：最后几步才动它');
    expect(start, greaterThan(0), reason: '手册里找不到字幕这一节了，回来看看');
    final end = skill.indexOf('\n## ', start + 1);
    expect(end, greaterThan(start), reason: '找不到这一节的结尾');
    return skill.substring(start, end);
  }

  test('手册里提到的字幕字段，报告里都要真有产出', () {
    final section = subtitleSection();
    // **从手册里抓真名，不手写白名单。** `` `.field` `` `` `.a.b` `` 这种
    // jq 路径才算数——纯英文词的反引号太容易撞上子命令名（`check`）、
    // 枚举值（`base`/`original`）、跨模块字段（`productBrand`）这类
    // 根本不该拿去核对 subtitle_view.dart 的东西，那会把这条测试
    // 变成另一种误报的白名单
    final mentioned = RegExp(r'`\.((?:[a-zA-Z]+\.)*[a-zA-Z]+)`')
        .allMatches(section)
        .expand((m) => m.group(1)!.split('.'))
        .toSet();

    // 抓取逻辑本身要是坏了（比如手册这一节被整段删掉、或者格式改了），
    // mentioned 会静静地变成空集，下面的 for 循环空转全绿——那样这条
    // 测试就名存实亡了。用几个必然会写到的字段兜底，抓不到就先说清楚
    // 是抓取坏了，不是字段真的都对
    expect(
      mentioned,
      containsAll(const ['heard', 'lines', 'voice', 'spillsInto']),
      reason: '按 `.字段名` 这个约定，从手册字幕节里一个字段都没抓到——'
          '要么这一节被删了，要么写法变了，这条测试现在是空转的',
    );

    for (final f in mentioned) {
      expect(view.contains("'$f'"), isTrue,
          reason: '手册说报告里有 $f，subtitle_view.dart 里却没有产出——'
              '照着写 jq 拿到一列 null，第一反应是「功能坏了」而不是「手册错了」');
    }
  });

  /// 手册不许把一个软件根本给不出来的东西当线索教出去。
  ///
  /// `AsrWord.confidence` 在真实数据里恒为 0（四条任务 1703/1703 个词），
  /// 火山 ASR 就是这么报的。现在解析那一层把 0 当成「没给」置成 null，
  /// 报告里这个键自然不出现——手册那条「低置信度的词是听错的高发处」
  /// 就成了一条走不通的路，认错别字的线索只剩 `productBrand` 和标签词表。
  test('手册不许拿 confidence 当认错别字的线索——软件给不出来', () {
    expect(subtitleSection().contains('confidence'), isFalse,
        reason: 'ASR 给的置信度恒为 0，报告里报不出这个键；'
            '教 Agent 去看它，等于教了一条死路');
  });

  test('手册里每条 ishkafel subtitle 子命令都要真能敲', () {
    // **真实子命令从代码的分发点抓，不是整份文件子串匹配。**
    // `command.contains("'$sub'")` 这种写法测得对是巧合——
    // `'subtitle.set'`（TaskMutation 的 op 名）没被误命中 `'set'`，
    // 纯属字符串边界凑巧躲开，下一次未必这么走运
    final real = RegExp(r"rest\.first == '([a-z]+)'")
        .allMatches(command)
        .map((m) => m.group(1)!)
        .toSet();
    expect(real, containsAll(const ['check', 'show']),
        reason: '抓不到真实分发的子命令，这条测试就是空转');

    final used = RegExp(r'ishkafel subtitle (\w+)')
        .allMatches(skill)
        .map((m) => m.group(1)!)
        .toSet();
    for (final sub in used) {
      expect(real.contains(sub), isTrue,
          reason: '手册写了 `ishkafel subtitle $sub`，命令的真实分发里认不出来'
              '（真实分发只认：${(real.toList()..sort()).join(' / ')}）');
    }
  });

  test('手册里至少要留着 check 和 show 这两个入口', () {
    // 上面那条测试是「手册提到的子命令都要真能敲」——手册整节被删掉的话，
    // 它的匹配集合会变成空集，空循环天然全绿，且没有任何提示。
    // `script_subcommands_real_test.dart` 早就踩过同一个坑，
    // 这里照抄它的下限断言
    expect(skill.contains('ishkafel subtitle check'), isTrue,
        reason: '手册里连 `subtitle check` 这个入口都没有了');
    expect(skill.contains('ishkafel subtitle show'), isTrue,
        reason: '手册里连 `subtitle show` 这个入口都没有了');
  });
}
