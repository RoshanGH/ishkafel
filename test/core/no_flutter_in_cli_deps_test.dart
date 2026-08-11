import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CLI 是纯 Dart 进程，没有 Flutter binding。这几个文件在 CLI 的依赖树上，
/// 一旦 import 了 package:flutter，编译 CLI 时直接失败（`dart build cli`）。
///
/// 用测试钉住而不是靠人记得：这类 import 常常是顺手加的（要个 @immutable
/// 就 import 了 foundation），而它坏掉的地方在另一个构建产物里——改的人
/// 在 GUI 上跑得好好的，直到某天有人去编 CLI 才发现。
void main() {
  const cliDependencies = [
    'lib/core/log/app_log.dart',
    'lib/core/storage/file_task_repository.dart',
    'lib/core/storage/task_repository.dart',
    'lib/core/models/export_record.dart',
    'lib/core/models/renew_task.dart',
    'lib/core/models/semantic_unit.dart',
    'lib/core/models/shot.dart',
    'lib/core/replacement/picked_material.dart',
    'lib/core/replacement/replacement_plan.dart',
    'lib/core/ffmpeg/media_spec.dart',
    'lib/core/ffmpeg/process_runner.dart',
  ];

  test('CLI 依赖树上的 core 文件不许 import flutter', () {
    final offenders = <String>[];
    for (final path in cliDependencies) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path 不存在，清单该更新了');
      if (file.readAsStringSync().contains('package:flutter/')) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty,
        reason: '这些文件在 CLI 依赖树上，import flutter 会让 dart build cli 失败');
  });
}
