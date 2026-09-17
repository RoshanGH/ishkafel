import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/shot_allocation.dart';

/// **这条线的时间根是口播。**
///
/// 用户的原话：「我们到底是用什么样的时间去做画面对齐的？我们用的是口播的
/// 时间呀。你都没有选音色去克隆口播，你怎么知道后面的镜头是多少秒呢？……
/// 它必须要有一个默认的音色，这个是必选的，来确定它的时长。」
///
/// 真机上看到的：编导台顶上写着「本片 · 未定音色」，而 Agent 已经在一句句
/// 地挑画面了。那时每一行的坑位时长都是 **0**——这一镜该多少秒、素材够不够
/// 铺、要不要变速，全都无从判断，挑出来的东西没有任何依据。
void main() {
  test('没有配音，这一行就没有时长根', () {
    final line = ScriptLine.create(text: '看到没有');
    expect(ShotAllocation.rootMsOf(line), isNull,
        reason: '这正是问题的源头：坑位时长退化成 0');
  });

  test('提取台词时就把音色定下来，不留空等着谁想起来', () {
    final src =
        File('lib/cli/commands/script_run_command.dart').readAsStringSync();
    // 取整个函数体，不要按字符数截窗口——往函数里加几行就会把要找的话
    // 推出窗口，测试红了却和它想守的东西毫无关系（真机上就发生过）
    final from = src.indexOf('runScriptExtractCommand');
    final rest = src.substring(from);
    final next = RegExp(r'\nFuture<int> ').firstMatch(rest);
    final extract = next == null ? rest : rest.substring(0, next.start);
    // Task 6 把这里的写入改走 TaskMutation：落盘那一刻改成
    // `fresh.script?.defaultVoiceId ?? baseline`——fresh 已经有默认音色时
    // 保留那个（可能是拿锁期间人自己定的），没有才补 baseline。行为比原来
    // 「一律用计算好的 baseline 覆盖」更对，但「没有默认音色时一定会补上
    // 一个」这条不变量没变
    expect(extract, contains('?? baseline'),
        reason: '音色是必选项——没有它，后面每一步的时长都是空的');
    expect(extract, contains('趁还没配音赶紧换'),
        reason: '定了默认不等于不能改，但要说清「配完再换要重配一轮」');
  });

  test('没配音就不许挑画面——挑了也是瞎挑', () {
    final src = File('lib/cli/commands/script_command.dart').readAsStringSync();
    expect(src, contains('还没配音，挑不了画面'),
        reason: '坑位时长是 0 的时候让它挑，等于让它闭着眼睛选');
    expect(src, contains('时间根是配音时长'),
        reason: '要把道理说给它听，不是只甩一个拒绝');
  });
}
