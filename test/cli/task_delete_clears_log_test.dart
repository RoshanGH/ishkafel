import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/tasks_command.dart';
import 'package:ishkafel/core/storage/task_log.dart';

import '../support/seed_task.dart';

/// 「不留孤儿数据」——磁盘上躺着的每一份数据都要有人读、有人删。
/// 任务没了，它的日志再没人会去看，留着就是垃圾。
void main() {
  test('删任务之后日志文件不在了', () async {
    final dataDir = Directory.systemTemp.createTempSync('ishkafel_del');
    addTearDown(() => dataDir.deleteSync(recursive: true));

    final task = await seedTask(dataDir);
    TaskLogFile(dataDir: dataDir, taskId: task.id)
        .append(by: ActorKind.agent, actor: 'Agent', op: 'shot.pick');
    expect(File('${dataDir.path}/logs/${task.id}.jsonl').existsSync(), isTrue);

    await runTaskDeleteCommand(
        rest: [task.id], dataDir: dataDir, yes: true, err: StringBuffer());

    expect(File('${dataDir.path}/logs/${task.id}.jsonl').existsSync(), isFalse,
        reason: '任务删了日志还躺在盘上，就是孤儿数据');
  });
}
