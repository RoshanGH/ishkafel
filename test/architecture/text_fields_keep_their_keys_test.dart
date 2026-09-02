import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **页面里的输入框都要拿回自己的按键。**
///
/// 编导台有全页快捷键（空格播放、←→ 秒跳、Esc、⌘A/⌘Z）。少包一个输入框，
/// 那个框里就打不出中文——中文输入法在拼音阶段按空格是选词上屏，被页面
/// 快捷键抢走后拼音永远上不了屏，而粘贴却是好的，极难往「快捷键」上想。
void main() {
  test('编导台页面内的输入框都包了 TextEditingKeys', () {
    // 对话框是独立路由，按键不会冒泡到页面级——不在这条规矩里
    const inPageFiles = [
      'lib/features/director/script_panel.dart',
      'lib/features/director/line_board.dart',
      'lib/features/director/find_shots_sheet.dart',
    ];
    for (final path in inPageFiles) {
      final src = File(path).readAsStringSync();
      if (!src.contains('TextField(')) continue;
      expect(src, contains('TextEditingKeys'),
          reason: '$path 里有输入框却没把按键留给它：'
              '这个框里的中文输入法会被全页快捷键打断');
    }
  });

  test('全页快捷键在人打字时让路', () {
    final src =
        File('lib/features/director/director_page.dart').readAsStringSync();
    final from = src.indexOf('return CallbackShortcuts(');
    expect(from, isNot(-1));
    final body = src.substring(from, src.indexOf('child: FocusScope', from));
    // 每一条绑定都要先问一句「人是不是正在输入框里」
    final bindings = 'const SingleActivator('.allMatches(body).length;
    final guards = 'isEditableTextFocused()'.allMatches(body).length;
    expect(guards, greaterThanOrEqualTo(bindings),
        reason: 'CallbackShortcuts 没有 isEnabled 那道闸，匹配上就无条件执行——'
            '漏一条，那个键在输入框里就会被抢走');
  });

  test('「人在打字吗」只有一份实现', () {
    final hits = <String>[];
    for (final dir in ['lib/core', 'lib/features']) {
      for (final f in Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        if (f.readAsStringSync().contains('bool isEditableTextFocused()')) {
          hits.add(f.path);
        }
      }
    }
    expect(hits, hasLength(1),
        reason: '两处各写一份，迟早一处改了另一处没改：\n${hits.join('\n')}');
  });
}
