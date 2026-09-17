import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **软件永远不对 Agent 说「不行」。**
///
/// 产品负责人的原话：「永远不要让 Agent 报一个问题说『我现在没有办法操作，
/// 因为软件那边没有给我权限』……任何它不应该做的事情，都应该是人告诉 Agent 的，
/// 而非是软件限制的。」
///
/// 命令失败的理由只剩三类：参数不对（exitBadUsage / exitNotFound）、
/// 外部依赖真的坏了（exitEnv）、干了没成（exitFailed）。**没有第四类。**
///
/// ---
///
/// **这份测试的盲区——别把它的绿灯当结论**（2026-09-18 评审列出）：
///
/// 1. **只看单行。** 话术扫描按行匹配，一句话拆成两行写就漏掉；
///    `unsupported` 那条按 ±8 行的窗口找，离得更远也会漏
/// 2. **只查措辞，不查退出码。** 一条命令完全可以用一句人畜无害的话
///    返回 `exitFailed`，这里一个字都拦不住——`export` / `apply plans` /
///    `review` 因为「人开着另一页」而失败那三条，就是这么躲过第一轮的
///    （它们的话术很正常，问题在退出码）
/// 3. **理由藏在变量里就看不见。** 拼在字符串里的禁用词扫得到，
///    先赋给一个变量再写出去的扫不到
///
/// 所以它挡的是**退化**（把删掉的话写回来），不是**证明**没有权限类拒绝。
/// 真正的证明只能靠逐条读路径——这三条盲区各自对应一次真实的漏网。
void main() {
  test('exitLocked 这个退出码不存在了', () {
    final src = File('lib/cli/cli_output.dart').readAsStringSync();
    expect(src.contains('exitLocked'), isFalse,
        reason: '「被别人占着」不是一种允许的失败理由，整个退出码要删掉');
  });

  test('没有任何地方还在 import 锁', () {
    final offenders = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      if (RegExp(r"import .*(task_lock|lock_yield|gui_lock_guidance|"
              r"agent_lock_holder)\.dart")
          .hasMatch(src)) {
        offenders.add(f.path.replaceFirst('${Directory.current.path}/', ''));
      }
    }
    expect(offenders, isEmpty,
        reason: '锁整套删掉了，这些地方还引着：\n${offenders.join('\n')}');
  });

  /// **「这一页接不了这个动作」不许当成失败。**
  ///
  /// `delegateOrDoItYourself` 只问「界面在不在这条任务上」，问不了「这一页
  /// 能不能接这个动作」。人开着审片台看这条任务时，`export` / `apply plans`
  /// 的委派会收到审片台那句「我不认识这件事」——不带标记的话，调用方把它
  /// 当真失败往上抛，Agent 得到的就是「我做不了，因为软件那边不让」，
  /// 而理由竟然是人开着另一页。
  ///
  /// 所以各页面对认不出的 kind 一律带 `unsupported: true`，命令读到它就
  /// 自己干。这两半缺一不可，各守一条。
  test('界面对认不出的动作一律带 unsupported 标记', () {
    const pages = [
      'lib/features/director/director_page.dart',
      'lib/features/workbench/workbench_page.dart',
      'lib/features/review/review_page.dart',
      'lib/features/tasks/task_list_page.dart',
    ];
    for (final path in pages) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!RegExp(r'(接不了|不认识)「').hasMatch(lines[i])) continue;
        if (lines[i].trimLeft().startsWith('//')) continue;
        final window = lines
            .sublist((i - 8).clamp(0, lines.length), (i + 3).clamp(0, lines.length))
            .join('\n');
        expect(window, contains('unsupported: true'),
            reason: '$path 第 ${i + 1} 行说「接不了」，却没带 unsupported——'
                '调用方会把它当真失败，Agent 就被「人开着另一页」挡住了');
      }
    }
  });

  test('命令收到 unsupported 一律自己干，不当失败', () {
    for (final path in const [
      'lib/cli/commands/export_command.dart',
      'lib/cli/commands/apply_command.dart',
      'lib/cli/commands/review_command.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src, contains('result.unsupported'),
          reason: '$path 没有分开「这一页接不了」和「试了没做成」——'
              '人开着另一页就会把这条命令整个挡住');
    }
  });

  test('失败话术里没有「权限类」的说辞——命令行和界面都算', () {
    const banned = [
      // 命令行那一侧
      '正在操作这个任务', '写不进去', '先等它', '被锁住',
      '界面没有回应', '占着，先不动它了',
      // 界面那一侧：打开一个任务不再需要「取得」什么，它就是打开
      '当前为只读', '强制接管', '自动解锁', '正在处理这个任务',
    ];
    final offenders = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final phrase in banned) {
        if (!src.contains(phrase)) continue;
        // 注释里回顾历史可以，真往 stderr 写就不行
        for (final line in src.split('\n')) {
          if (!line.contains(phrase)) continue;
          if (line.trimLeft().startsWith('//')) continue;
          if (line.trimLeft().startsWith('///')) continue;
          offenders.add('${f.uri.pathSegments.last}：${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: '这些话是软件在对 Agent 说「不行」，一条都不许留：\n'
            '${offenders.toSet().join('\n')}');
  });
}
