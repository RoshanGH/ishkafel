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

  test('CLI 的失败话术里没有「权限类」的说辞', () {
    const banned = ['正在操作这个任务', '写不进去', '先等它', '被锁住',
      '界面没有回应', '占着，先不动它了'];
    final offenders = <String>[];
    for (final f in Directory('lib/cli')
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
