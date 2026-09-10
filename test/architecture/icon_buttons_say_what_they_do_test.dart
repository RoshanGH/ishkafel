import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **只有图标的按钮必须说得出自己是干什么的。**
///
/// 2026-09-09 设计走查：播放控制条那五个键（⏮ ‹ ▶ › ⏭）全是纯图标、
/// 一个 tooltip 都没有——人既猜不出「⏮」是回片头还是上一镜，也无从知道
/// 这些操作还有键盘可用。专业工具的 tooltip 里连快捷键一起写，这是
/// 「人能不能自己学会用」的关键一环。
void main() {
  test('每个 IconButton 都有 tooltip', () {
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = file.readAsStringSync();
      for (final m in RegExp(r'IconButton\(').allMatches(src)) {
        var i = m.end;
        var depth = 1;
        while (i < src.length && depth > 0) {
          if (src[i] == '(') {
            depth++;
          } else if (src[i] == ')') {
            depth--;
          }
          i++;
        }
        final body = src.substring(m.end, i);
        if (!body.contains('tooltip')) {
          final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
          offenders.add('${file.path}:$line');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: '这些图标按钮不说自己干什么：\n${offenders.join('\n')}\n'
            '加 tooltip；有快捷键的连快捷键一起写（「播放　空格」）');
  });
}
