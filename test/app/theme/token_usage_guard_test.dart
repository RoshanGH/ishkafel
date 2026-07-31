import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 已 token 化的目录。新目录完成迁移后加进来，让守卫覆盖面只增不减。
const _guardedDirs = <String>[
  'lib/features/workbench',
  'lib/features/tasks',
  'lib/features/settings',
  'lib/features/home',
  'lib/features/picking',
];

/// 同时盯住 `fontSize: 12` 与 `fontSize = 12` 两种写法——只匹配前者的话，
/// 迁移时换个赋值形式就能绕过守卫。
final _inlineFontSize = RegExp(r'fontSize\s*[:=]\s*\d');

void main() {
  group('设计 token 防漂移守卫', () {
    test('已迁移目录里不再出现内联字号', () {
      final offenders = <String>[];
      for (final dir in _guardedDirs) {
        for (final entity in Directory(dir).listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final lines = entity.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            if (_inlineFontSize.hasMatch(lines[i])) {
              offenders.add('${entity.path}:${i + 1}  ${lines[i].trim()}');
            }
          }
        }
      }

      expect(offenders, isEmpty,
          reason: '字号必须取 AppFontSize 的 5 级阶梯。改造前全项目散落 8 种字号'
              '（10/10.5/11/11.5/12/12.5/13/15），相邻两级只差 0.5px 读不出层级、'
              '只会让排版发糊；没有守卫的话新代码会一点点把它加回来：\n'
              '${offenders.join('\n')}');
    });
  });
}
