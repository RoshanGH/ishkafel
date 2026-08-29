import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 废弃的词不许从**面向人和 Agent 的文字**里漏出去。
///
/// 真机撞到过：手册和界面都改成「替换裂变 / replace」了，而
/// `ui new-task` 参数写错时的报错还在说「--mode 要是 script / renew / blank
/// 之一」——人照着报错去敲，写出来的就是那个废弃的词。
///
/// 兼容旧值是对的（不让写好的脚本一夜失效），但**不能再教人用它**。
void main() {
  final retired = {
    '成片翻新': '替换裂变',
    'renew': 'replace',
  };

  test('CLI 的提示与报错里不出现废弃的词', () {
    final offenders = <String>[];
    for (final f in [
      ...Directory('lib/cli').listSync(recursive: true),
      ...Directory('bin').listSync(),
    ].whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final line in src.split('\n')) {
        // 只看写给人看的字符串：跳过注释、import、以及兼容用的解析表
        final t = line.trimLeft();
        if (t.startsWith('//') || t.startsWith('import ') ||
            t.startsWith('export ')) {
          continue;
        }
        if (line.contains('_legacy') || line.contains('旧名')) continue;
        for (final entry in retired.entries) {
          if (!line.contains("'") && !line.contains('"')) continue;
          if (!line.contains(entry.key)) continue;
          // renew 只在成词时算（renewTask 之类的标识符不算）
          if (entry.key == 'renew' &&
              !RegExp(r'[^A-Za-z]renew[^A-Za-z]').hasMatch(line)) {
            continue;
          }
          offenders.add('${f.path}: ${line.trim()}');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: '这些提示还在教人用废弃的词：\n${offenders.join('\n')}');
  });
}
