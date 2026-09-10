import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **块级间距走 4pt 网格，不许出现 11 / 14 / 15 这种数。**
///
/// 2026-09-10 走查：面板内边距混着 10 / 11 / 14 / 15 —— 单看每一处都
/// 「差不多」，摆在一起就是一套没有节奏的排版。CLAUDE.md 要的是
/// 「精致的间距系统（4pt 网格）」。
///
/// **小于 10 的不管**：图标与文字之间那 2、3 像素是刻意的微调，
/// 硬拉到 4 的倍数反而会把图标顶歪。网格约束的是块与块之间的呼吸。
void main() {
  test('10 以上的内边距都是 4 的倍数（或走 AppSpacing）', () {
    final offenders = <String>[];
    final call = RegExp(r'EdgeInsets\.(?:all|symmetric|only|fromLTRB)\(([^)]*)\)');
    final number = RegExp(r'(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])');

    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (file.path.contains('app/theme')) continue;
      final lines = file.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        for (final m in call.allMatches(code)) {
          for (final n in number.allMatches(m.group(1)!)) {
            final v = double.parse(n.group(1)!);
            if (v >= 10 && v % 4 != 0) {
              offenders.add('${file.path}:${i + 1}  $v');
            }
          }
        }
      }
    }

    expect(offenders, isEmpty,
        reason: '这些块级间距不在 4pt 网格上：\n${offenders.join('\n')}\n'
            '用 AppSpacing.md/lg/xl，或者收到最近的 4 的倍数');
  });
}
