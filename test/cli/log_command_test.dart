import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/log_command.dart';
import 'package:ishkafel/core/storage/task_log.dart';

import '../support/seed_task.dart';

void main() {
  late Directory dataDir;
  setUp(() => dataDir = Directory.systemTemp.createTempSync('ishkafel_logcmd'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  test('--json 一行一条，字段名和盘上一致', () async {
    final taskId = (await seedTask(dataDir)).id;
    TaskLogFile(dataDir: dataDir, taskId: taskId).append(
      by: ActorKind.human,
      actor: '人（工作台）',
      op: 'shot.remove',
      where: {'unitUid': 'u-abc', 'shot': 1},
      before: {'materialId': 105475, 'tags': ['实拍', '产品特写']},
    );

    final out = StringBuffer();
    final code = await runLogCommand(rest: [taskId], dataDir: dataDir, out: out);

    expect(code, 0);
    final rows = const LineSplitter().convert(out.toString().trim());
    final row = jsonDecode(rows.single) as Map<String, dynamic>;
    expect(row['by'], 'human');
    expect(row['op'], 'shot.remove');
    expect((row['before'] as Map)['tags'], ['实拍', '产品特写']);
  });

  test('--by human 只给人干的', () async {
    final taskId = (await seedTask(dataDir)).id;
    final log = TaskLogFile(dataDir: dataDir, taskId: taskId);
    log.append(by: ActorKind.agent, actor: 'Agent', op: 'a');
    log.append(by: ActorKind.human, actor: '人', op: 'b');

    final out = StringBuffer();
    await runLogCommand(
        rest: [taskId], dataDir: dataDir, by: 'human', out: out);
    final rows = const LineSplitter().convert(out.toString().trim());
    expect(rows, hasLength(1));
    expect((jsonDecode(rows.single) as Map)['op'], 'b');
  });

  test('任务不存在 → exitNotFound，报错说得出是哪个 id', () async {
    final err = StringBuffer();
    final code =
        await runLogCommand(rest: ['没这条'], dataDir: dataDir, err: err);
    expect(code, exitNotFound);
    expect(err.toString(), contains('没这条'));
  });

  test('--by 写错不是「没结果」，是当场点名', () async {
    final taskId = (await seedTask(dataDir)).id;
    final err = StringBuffer();
    final code = await runLogCommand(
        rest: [taskId], dataDir: dataDir, by: '人类', err: err);
    expect(code, exitBadUsage);
    expect(err.toString(), contains('human'));
    expect(err.toString(), contains('agent'));
  });

  test('还没有任何改动时，说「还没有改动」而不是空着', () async {
    final taskId = (await seedTask(dataDir)).id;
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runLogCommand(
        rest: [taskId], dataDir: dataDir, json: false, out: out, err: err);
    expect(code, 0);
    expect('${out.toString()}${err.toString()}', contains('还没有改动'));
  });
}
