import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/tasks_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// `ishkafel task-rename` —— 界面上人能改名，Agent 之前不能。
void main() {
  late Directory dir;
  late FileTaskRepository repo;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('rename_');
    repo = FileTaskRepository(dir);
    await repo.save(RenewTask(
      id: 't1',
      name: '脚本 08-27 21:52',
      sourcePath: null,
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 27),
      updatedAt: DateTime.utc(2026, 8, 27),
      units: const [],
      seq: 6,
    ));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('改完就是新名字', () async {
    expect(
        await runTaskRenameCommand(
            rest: ['t1'], dataDir: dir, name: '验证-复刻滴露'),
        0);
    expect((await repo.findById('t1'))!.name, '验证-复刻滴露');
  });

  test('短编号也认', () async {
    await runTaskRenameCommand(rest: ['#6'], dataDir: dir, name: '改了');
    expect((await repo.findById('t1'))!.name, '改了');
  });

  test('不给名字就说用法，不把名字改成空', () async {
    expect(
        await runTaskRenameCommand(
            rest: ['t1'], dataDir: dir, err: StringBuffer()),
        exitBadUsage);
    expect((await repo.findById('t1'))!.name, '脚本 08-27 21:52');
  });

  test('回报改之前叫什么——人才对得上是哪一条', () async {
    final out = StringBuffer();
    await runTaskRenameCommand(
        rest: ['t1'], dataDir: dir, name: '新的', out: out);
    expect(out.toString(), contains('脚本 08-27 21:52'));
  });
}
