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

  test('--limit 给负数不许崩，要当场点名合法范围', () async {
    final taskId = (await seedTask(dataDir)).id;
    final err = StringBuffer();
    final code = await runLogCommand(
        rest: [taskId], dataDir: dataDir, limit: -1, err: err);
    expect(code, exitBadUsage);
    expect(err.toString(), contains('limit'));
  });

  test('--since 给负数同样当场点名，不许崩', () async {
    final taskId = (await seedTask(dataDir)).id;
    final err = StringBuffer();
    final code = await runLogCommand(
        rest: [taskId], dataDir: dataDir, since: -1, err: err);
    expect(code, exitBadUsage);
    expect(err.toString(), contains('since'));
  });

  test('before/after 同名字段要显示对比，不能被展开覆盖掉一边', () async {
    final taskId = (await seedTask(dataDir)).id;
    TaskLogFile(dataDir: dataDir, taskId: taskId).append(
      by: ActorKind.human,
      actor: '人（工作台）',
      op: 'shot.replace',
      before: {'materialId': 105},
      after: {'materialId': 200},
    );

    final out = StringBuffer();
    final code = await runLogCommand(
        rest: [taskId], dataDir: dataDir, json: false, out: out);
    expect(code, 0);
    // 两边的值都要在——不能只剩 after 那一边
    expect(out.toString(), contains('materialId：105 → 200'));
  });

  test('--by 过滤后没查到，提示要点名过滤条件，不能看着像「真的没有」', () async {
    final taskId = (await seedTask(dataDir)).id;
    TaskLogFile(dataDir: dataDir, taskId: taskId)
        .append(by: ActorKind.human, actor: '人', op: 'a');

    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runLogCommand(
        rest: [taskId],
        dataDir: dataDir,
        json: false,
        by: 'agent',
        out: out,
        err: err);
    expect(code, 0);
    final combined = '${out.toString()}${err.toString()}';
    expect(combined, contains('还没有改动'));
    expect(combined, contains('agent'));
  });

  test('跨天的记录要带出日期，不然分不清「今天」和「哪天」', () async {
    final taskId = (await seedTask(dataDir)).id;
    final file = File('${dataDir.path}/logs/$taskId.jsonl');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${jsonEncode({
          'at': '2020-01-01T09:05:00.000',
          'by': 'human',
          'actor': '人',
          'task': taskId,
          'op': 'old.op',
        })}\n');

    final out = StringBuffer();
    final code = await runLogCommand(
        rest: [taskId], dataDir: dataDir, json: false, out: out);
    expect(code, 0);
    expect(out.toString(), contains('01-01 09:05'));
  });

  test('日志文件读不动要报 exitFailed，不能说成「还没有改动」', () async {
    final taskId = (await seedTask(dataDir)).id;
    // 把该是文件的路径误建成目录，模拟「存在但读不了」
    Directory('${dataDir.path}/logs/$taskId.jsonl').createSync(recursive: true);

    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runLogCommand(
        rest: [taskId], dataDir: dataDir, out: out, err: err);
    expect(code, exitFailed);
    expect(err.toString(), isNotEmpty);
    expect(out.toString(), isNot(contains('还没有改动')));
    expect(err.toString(), isNot(contains('还没有改动')));
  });
}
