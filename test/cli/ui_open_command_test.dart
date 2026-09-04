import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/ui_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/core/storage/ui_where.dart';

/// `ishkafel ui open <任务>` —— **把界面叫到现场**。
///
/// 在这条命令之前，可视模式只有出口没有入口：`ui tasks` 能把界面支开，
/// 却没有任何办法把它叫回来。真机上 Agent 为了拿写锁调了 `ui tasks`，
/// 界面退到任务列表，此后二十句配音全程在列表页上以文字滚过——
/// 可视化就此结束，而且回不去。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('uiopen');
    repo = FileTaskRepository(dir);
    await repo.save(RenewTask(
      id: 's1',
      name: '脚本片',
      status: RenewTaskStatus.ready,
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
      script: ScriptDoc([ScriptLine.create(text: '一句台词')]),
    ));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<(int, String, String)> run(List<String> rest, {String? module}) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runUiCommand(
      rest: rest,
      dataDir: dir,
      module: module,
      run: (_, _) async => ProcessResult(0, 0, '', ''),
      appExists: (_) => true,
      waitForUi: const Duration(milliseconds: 50),
      out: out,
      err: err,
    );
    return (code, '$out', '$err');
  }

  Map<String, dynamic>? wake() {
    final f = File('${dir.path}/ui_wake.json');
    return f.existsSync()
        ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
        : null;
  }

  test('把界面带到这条任务的编导台', () async {
    final (code, _, _) = await run(['open', 's1']);
    expect(code, 0);
    expect(wake()?['task'], 's1');
    expect(wake()?['module'], 'director', reason: '脚本成片的工作页是编导台');
  });

  test('界面已经在那一页：不再唤醒，别把页面销毁重建', () async {
    writeUiWhere(dir, module: 'director', taskId: 's1');
    final (code, jsonOut, _) = await run(['open', 's1']);
    expect(code, 0);
    expect(wake(), isNull,
        reason: '已经在现场还发唤醒，滚动位置和展开的镜头全丢——画面会弹回第一行');
    expect(jsonDecode(jsonOut)['already'], isTrue);
  });

  test('可以指定去哪个模块', () async {
    final (code, _, _) = await run(['open', 's1'], module: 'review');
    expect(code, 0);
    expect(wake()?['module'], 'review');
  });

  test('没有这个任务就直说', () async {
    final (code, _, log) = await run(['open', '不存在']);
    expect(code, isNot(0));
    expect(log, contains('没有这个任务'));
  });

  test('模块名写错要点名，别默默去了别的地方', () async {
    final (code, _, log) = await run(['open', 's1'], module: 'timeline');
    expect(code, isNot(0));
    expect(log, contains('director'));
  });

  test('用法里要列出 open——手册和报错是 Agent 唯一的入口', () async {
    final (code, _, log) = await run([]);
    expect(code, isNot(0));
    expect(log, contains('ui open'));
  });
}
