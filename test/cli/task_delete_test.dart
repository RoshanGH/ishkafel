import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/tasks_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/core/storage/task_media.dart';

/// `ishkafel task delete <id>` —— 删掉一条任务。
///
/// 验收 Agent 卡在这儿：让它「验完自己删掉」，但 CLI 根本没有这条命令。
/// 它的原话——「这一次是最没有借口的：不是我懒，是 CLI 真的没有这条路」，
/// 于是只能眼睁睁看着界面上的 ⋯ 菜单不敢点。
///
/// 界面上人能删，Agent 就得能删。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('task_del_');
    repo = FileTaskRepository(dir);
    await repo.save(RenewTask(
      id: 't1',
      name: '要删的',
      sourcePath: null,
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 27),
      updatedAt: DateTime.utc(2026, 8, 27),
      units: const [],
      seq: 7,
    ));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int> del(List<String> rest,
          {bool yes = true, StringSink? out, StringSink? err}) =>
      runTaskDeleteCommand(
          rest: rest, dataDir: dir, yes: yes, out: out, err: err);

  test('删掉之后任务就不在了', () async {
    expect(await del(['t1']), 0);
    expect(await repo.findById('t1'), isNull);
  });

  test('短编号也认——人和 Agent 说的都是 #7', () async {
    expect(await del(['#7']), 0);
    expect(await repo.findById('t1'), isNull);
  });

  test('物料跟着一起走，不留孤儿', () async {
    final media = TaskMedia(dataDir: dir, taskId: 't1');
    media.materialsDir.createSync(recursive: true);
    File('${media.materialsDir.path}/1.mp4').writeAsStringSync('x');
    await del(['t1']);
    expect(media.materialsDir.existsSync(), isFalse);
  });

  test('不加 --yes 就不删——删任务是不可逆的', () async {
    final err = StringBuffer();
    expect(await del(['t1'], yes: false, err: err), exitBadUsage);
    expect(await repo.findById('t1'), isNotNull);
    expect(err.toString(), contains('--yes'));
  });

  test('没有这个任务时直说，不假装删成功', () async {
    expect(await del(['没有这个'], err: StringBuffer()), exitNotFound);
  });

  test('回报删的是哪一条——别让人删完还不知道删了什么', () async {
    final out = StringBuffer();
    await del(['t1'], out: out);
    expect(out.toString(), contains('要删的'));
  });
}
