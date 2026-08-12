import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/skill_command.dart';
import 'package:path/path.dart' as p;

/// `ishkafel skill` —— 让工具自己把说明书交出来。
///
/// 这是「怎么把方法论送到干活的那个 Agent 手上」的答案：不靠拷文件，
/// 靠问工具要。这样版本永远对得上。
void main() {
  test('不带参数就把手册打到标准输出', () async {
    final out = StringBuffer();
    final code = await runSkillCommand(rest: const [], out: out);
    expect(code, 0);
    expect(out.toString(), contains('用 ishkafel CLI 做成片翻新'));
    expect(out.toString(), contains('ishkafel candidates'));
  });

  test('--install 写进两家 Agent 的技能目录，且带 frontmatter', () async {
    final home = Directory.systemTemp.createTempSync('skill_cmd');
    addTearDown(() => home.deleteSync(recursive: true));

    final out = StringBuffer();
    final code = await runSkillCommand(
        rest: const [], install: true, home: home.path, out: out);
    expect(code, 0);

    for (final dir in ['.claude', '.codex']) {
      final file =
          File(p.join(home.path, dir, 'skills', 'ishkafel', 'SKILL.md'));
      expect(file.existsSync(), isTrue, reason: '$dir 该有一份');
      expect(file.readAsStringSync(), startsWith('---\n'));
    }
  });

  test('多给了参数就报用法，不当没看见', () async {
    final err = StringBuffer();
    final code = await runSkillCommand(rest: const ['乱写'], err: err);
    expect(code, isNot(0));
    expect(err.toString(), contains('用法'));
  });
}
