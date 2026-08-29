import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 手册里那份「支持可视的命令」清单是**手写的**，于是它过时了：
/// 加了 `candidates --visual`、`apply plans --visual` 之后清单没跟上，
/// 验收 Agent 照着清单以为它们不支持可视（洞 19）。
///
/// 这条测试拿代码里的事实去对手册——清单漏了哪条，测试就说哪条。
void main() {
  test('手册的可视命令清单要跟代码对得上', () {
    final skill = File('docs/AGENT_SKILL.md').readAsStringSync();
    // 手册里那一段
    final section = RegExp(r'支持可视的命令：([\s\S]{0,400}?)。')
        .firstMatch(skill)
        ?.group(1);
    expect(section, isNotNull, reason: '手册里找不到那份清单了');

    // 代码里真正接了 visual 的顶层命令
    final bin = File('bin/ishkafel.dart').readAsStringSync();
    final wired = <String>{};
    // 按分支切开再看：跨分支匹配会把相邻命令误算进来
    final branches = bin.split(RegExp(r"\n    '"));
    for (final b in branches) {
      final name = RegExp(r"^([a-z-]+)' =>").firstMatch(b)?.group(1);
      if (name == null) continue;
      if (b.contains('visual:')) wired.add(name);
    }

    final missing = [
      for (final c in wired)
        if (!section!.contains(c)) c,
    ];
    expect(missing, isEmpty,
        reason: '这些命令支持可视，手册的清单里却没有：${missing.join('、')}');
  });
}
