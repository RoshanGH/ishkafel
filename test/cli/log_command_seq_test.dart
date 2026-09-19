import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/log_command.dart';
import 'package:ishkafel/core/storage/task_log.dart';

import '../support/seed_task.dart';

/// **机器可读那条路也要有游标。**
///
/// 手册明着教 Agent 用 `--since <游标>` 接着上次看到的地方读，而
/// `TaskLogEntry.toJson()` 刻意不写 `seq`（它是读时按行序现算的，
/// 不落盘）。`log --json` 直接把 `toJson()` 吐出去的话，一行里一个游标
/// 字段都没有——Agent 只能自己数行，而**一旦命中 `limit`（默认 200、
/// 而且取的是最近的）或者用了 `--by` 过滤就必然数错**：数出来的号比真的
/// 小，下一次 `--since` 会把已经看过的重读一遍，或者更糟——数大了就漏读。
void main() {
  late Directory dataDir;
  setUp(() => dataDir = Directory.systemTemp.createTempSync('ishkafel_logseq'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  Future<List<Map<String, dynamic>>> rowsOf(
      {required String taskId, String? by, int? since, int limit = 200}) async {
    final out = StringBuffer();
    final code = await runLogCommand(
        rest: [taskId],
        dataDir: dataDir,
        by: by,
        since: since,
        limit: limit,
        out: out);
    expect(code, 0);
    return [
      for (final line in const LineSplitter().convert(out.toString().trim()))
        jsonDecode(line) as Map<String, dynamic>,
    ];
  }

  test('每行都带 seq，照着它就能 --since 接着读', () async {
    final taskId = (await seedTask(dataDir)).id;
    final log = TaskLogFile(dataDir: dataDir, taskId: taskId);
    for (var i = 0; i < 3; i++) {
      log.append(by: ActorKind.agent, actor: 'Agent', op: 'op$i');
    }

    final rows = await rowsOf(taskId: taskId);
    expect([for (final r in rows) r['seq']], [1, 2, 3],
        reason: '人读的版式里有 #seq，机器可读这条路却一个游标都没有');

    final after = await rowsOf(taskId: taskId, since: rows[1]['seq'] as int);
    expect([for (final r in after) r['op']], ['op2'],
        reason: 'json 里给的 seq 要真能当 --since 的游标用');
  });

  test('--by 过滤之后，seq 还是那一笔在全份日志里的真号', () async {
    final taskId = (await seedTask(dataDir)).id;
    final log = TaskLogFile(dataDir: dataDir, taskId: taskId);
    log.append(by: ActorKind.agent, actor: 'Agent', op: 'a');
    log.append(by: ActorKind.human, actor: '人', op: 'b');
    log.append(by: ActorKind.agent, actor: 'Agent', op: 'c');

    final rows = await rowsOf(taskId: taskId, by: 'human');
    expect(rows.single['seq'], 2,
        reason: '自己数行会数成 1——下一次 --since 1 会把第 2 笔重读一遍');
  });

  test('命中 limit 时给的是真号，不是从 1 数起', () async {
    final taskId = (await seedTask(dataDir)).id;
    final log = TaskLogFile(dataDir: dataDir, taskId: taskId);
    for (var i = 0; i < 5; i++) {
      log.append(by: ActorKind.agent, actor: 'Agent', op: 'op$i');
    }

    final rows = await rowsOf(taskId: taskId, limit: 2);
    expect([for (final r in rows) r['seq']], [4, 5],
        reason: '取的是最近两条，自己数行会数成 1、2，'
            '照着它 --since 会把前面三条又读一遍');
  });

  test('seq 只在命令行这一层加，不许写进盘上那一行', () async {
    final taskId = (await seedTask(dataDir)).id;
    TaskLogFile(dataDir: dataDir, taskId: taskId)
        .append(by: ActorKind.agent, actor: 'Agent', op: 'a');
    final raw = File('${dataDir.path}/logs/$taskId.jsonl').readAsStringSync();
    expect(jsonDecode(raw.trim()) as Map, isNot(contains('seq')),
        reason: 'seq 落盘就等于把「读-改-写」的撞号问题请回来（见 TaskLogEntry.seq）');
  });
}
