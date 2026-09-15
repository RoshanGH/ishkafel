import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **界面上的字不许带 Markdown 记号。**
///
/// Flutter 的 `Text` 一个字不解析，`**要花钱**` 会原样显示成带星号的四个字。
/// 2026-09-15 真机走查当场看到：确认框里写着「然后**逐镜看图打标**」——
/// 一条本来是要提醒人「这一步花钱」的话，看上去像是没写完的排版。
///
/// 只管**给人看**的那些（Text / title / subtitle / description / content…）。
/// 给 Agent 的 CLI 输出、给模型的 prompt 里 Markdown 是有意义的，不在此列。
void main() {
  /// UI 参数名出现在这些位置，说明这串字是给人看的
  const uiKeys = [
    'Text(',
    'title:',
    'subtitle:',
    'description:',
    'content:',
    'label:',
    'hintText:',
    'tooltip:',
    'helperText:',
  ];

  test('lib/features 下给人看的文案里没有 ** 记号', () {
    final bad = <String>[];
    for (final f in Directory('lib/features')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final t = line.trimLeft();
        // 注释里写 **强调** 是给读代码的人看的，不进界面
        if (t.startsWith('//') || t.startsWith('*')) continue;
        if (!RegExp(r"'[^']*\*\*").hasMatch(line)) continue;
        // 往上看几行：这串字是挂在某个 UI 参数上的吗
        final around = lines
            .sublist((i - 8).clamp(0, i), i + 1)
            .where((l) {
              final lt = l.trimLeft();
              return !lt.startsWith('//') && !lt.startsWith('*');
            })
            .join('\n');
        if (uiKeys.any(around.contains)) {
          bad.add('${f.path}:${i + 1}  ${line.trim()}');
        }
      }
    }

    expect(bad, isEmpty,
        reason: 'Text 不解析 Markdown，这些地方会原样显示出星号：\n'
            '${bad.join('\n')}\n'
            '要强调就换句式，或者用「」，别指望加粗');
  });
}
