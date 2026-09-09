import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **空格既要能打字，又要能播放/暂停。**
///
/// 两条规矩缺一不可：
/// 1. 焦点在输入框里时，空格归输入法（拼音阶段是选词上屏）——由输入框上的
///    `TextEditingKeys` 与快捷键的 `isEditableTextFocused` 保证；
/// 2. 人打完字点到别处，焦点必须真的走掉——否则第 1 条会一直成立，空格永远
///    到不了播放器。macOS 上点别处**不会**自动失焦，得显式接 `onTapOutside`。
///
/// 2026-09-09 真机，用户原话：「你改了打字输入中文之后，空格就不能正常暂停
/// 播放了。」漏的正是第 2 条。少接一个输入框，空格就在那一个上失灵，而这种
/// 失灵没有任何报错——所以在这里点名把它们列出来。
///
/// 名单只收**常驻页面上**的输入框。弹层（选音色、选配乐、选标签）里的不用：
/// 弹层一关焦点就跟着没了。
void main() {
  test('页面上的输入框都要接 onTapOutside', () {
    const fields = {
      // 工作台：单元台词
      'lib/features/workbench/inspector_panel.dart': 1,
      // 工作台：这一镜的字幕
      'lib/features/workbench/subtitle_editor_card.dart': 1,
      // 编导台：脚本正文
      'lib/features/director/script_panel.dart': 1,
      // 编导台：屏幕字
      'lib/features/director/line_board.dart': 1,
    };

    final offenders = <String>[];
    for (final entry in fields.entries) {
      final src = File(entry.key).readAsStringSync();
      final textFields = 'TextField('.allMatches(src).length;
      final released = 'onTapOutside:'.allMatches(src).length;
      if (released < entry.value) {
        offenders.add('${entry.key}：$textFields 个输入框，只有 $released 个'
            '接了 onTapOutside');
      }
    }

    expect(offenders, isEmpty,
        reason: '这些输入框打完字点到别处不会失焦，空格就再也回不到播放器：\n'
            '${offenders.join('\n')}');
  });
}
