import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 报告里出现的每个字段名，`subtitle_view.dart` 里必须真有对应产出；
/// 手册里写的每条 `ishkafel subtitle X` 都要真能敲。
///
/// **从代码里抓真名，不手写白名单**——手写的名单漏过 `script` 整整一条线。
void main() {
  final view = File('lib/cli/subtitle_view.dart').readAsStringSync();
  final skill = File('docs/AGENT_SKILL.md').readAsStringSync();
  final command = File('lib/cli/commands/subtitle_command.dart').readAsStringSync();

  test('手册里提到的字幕字段，报告里都要真有', () {
    for (final f in const [
      'heard', 'lines', 'frames', 'voice', 'problems', 'spillsInto', 'fpsSource',
      'caption', 'maxCharsPerScreen', 'willWrap', 'burned', 'framesUnavailable',
    ]) {
      expect(view.contains("'$f'"), isTrue,
          reason: '手册说报告里有 $f，subtitle_view.dart 里却没有产出——'
              '照着写 jq 拿到一列 null，第一反应是「功能坏了」而不是「手册错了」');
    }
  });

  test('手册里每条 ishkafel subtitle 子命令都要真能敲', () {
    final used = RegExp(r'ishkafel subtitle (\w+)')
        .allMatches(skill)
        .map((m) => m.group(1)!)
        .toSet();
    for (final sub in used) {
      expect(command.contains("'$sub'"), isTrue,
          reason: '手册写了 `ishkafel subtitle $sub`，命令里认不出来');
    }
  });
}
