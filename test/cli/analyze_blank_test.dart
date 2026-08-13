import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/analyze_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// `ishkafel analyze` 碰上空白任务。
void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_analyze_blank_');
    await FileTaskRepository(dir).save(RenewTask(
      id: 'b1',
      name: '拼片',
      sourcePath: null, // 空白任务
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 12),
      updatedAt: DateTime.utc(2026, 8, 12),
      units: const [],
    ));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('直接拒绝，并说清这条任务该怎么走', () async {
    final err = StringBuffer();
    final code = await runAnalyzeCommand(rest: ['b1'], dataDir: dir, err: err);

    expect(code, exitBadUsage);
    // 让它掉进管线的话，报出来的是「Bad state: ...」——那是给程序员看的
    expect(err.toString(), isNot(contains('Bad state')));
    expect(err.toString(), contains('空白任务'));
    expect(err.toString(), contains('blank tags'));
  });
}
