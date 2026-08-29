import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/top_level_commands.dart';

/// 用法行里写的命令**必须真的能敲通**。
///
/// 真机撞到：`ishkafel task-delete` 报「用法：ishkafel task **delete**
/// <任务 id> --yes」——照着敲得到「未知命令」。人（和 Agent）最信任的
/// 就是报错里给的那条命令。
void main() {
  test('提示里出现的 ishkafel 命令都要真的存在', () {
    final known = topLevelCommands.toSet();
    final offenders = <String>[];

    for (final f in Directory('lib/cli')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      for (final line in f.readAsStringSync().split('\n')) {
        for (final m
            in RegExp(r'ishkafel ([a-z][a-z-]+)').allMatches(line)) {
          final cmd = m.group(1)!;
          if (!known.contains(cmd)) offenders.add('${f.path}: $cmd');
        }
      }
    }

    expect(offenders.toSet(), isEmpty,
        reason: '这些提示里写了不存在的命令，照着敲会拿到「未知命令」：\n'
            '${offenders.toSet().join('\n')}');
  });
}
