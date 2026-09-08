import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CLI 的**选项表**能不能建起来。
///
/// 2026-09-07 踩过一次：新命令加了 `--to` 和 `--volume`，而 `bgm` 早就有同名
/// 选项。`ArgParser` 是**运行期**才抛 `Duplicate option`——`flutter analyze`
/// 干净、三千多项单测全绿，而 `ishkafel` 一执行就崩，**整个 CLI 全废**，
/// 不只是新命令。
///
/// 那次是打包脚本最后真跑了一次 `--help` 才逮住的。这条测试把它前移：
/// 加重名选项，这里当场红。
void main() {
  test('选项表里没有重名——重名会让整个 CLI 一执行就崩', () {
    final source = File('bin/ishkafel.dart').readAsStringSync();
    final names = <String>[];
    for (final m
        in RegExp(r"addOption\(\s*'([a-z-]+)'").allMatches(source)) {
      names.add(m.group(1)!);
    }
    for (final m in RegExp(r"addFlag\(\s*'([a-z-]+)'").allMatches(source)) {
      names.add(m.group(1)!);
    }

    final seen = <String>{};
    final duplicated = [
      for (final n in names)
        if (!seen.add(n)) n,
    ];

    expect(duplicated, isEmpty,
        reason: '这些选项定义了不止一次：${duplicated.join('、')}。'
            'ArgParser 会在运行期抛 Duplicate option，'
            '结果是 ishkafel 任何命令都跑不了——'
            '两个命令要用同名参数就共用一个定义，把帮助文案写成两句');
  });

  test('至少有一个选项被读到——正则失效时不能假装通过', () {
    final source = File('bin/ishkafel.dart').readAsStringSync();
    expect(RegExp(r"addOption\(\s*'([a-z-]+)'").allMatches(source).length,
        greaterThan(10),
        reason: '一个都没匹配到说明正则跟代码写法脱节了，'
            '这条测试就变成了永远绿的摆设');
  });
}
