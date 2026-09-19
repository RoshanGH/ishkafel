import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/status_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// **`status` 两条通道都要报。**
///
/// Agent 的在场状态（播报通道）和「软件自己在忙」是两个文件——分开是为了
/// 让播报只报 Agent，**不是让 status 装作看不见软件那一边**。
///
/// 界面跑分析、界面生成配音、界面打参考镜标，都会让 Agent 紧接着的命令
/// 被劝退。status 里一个字都没有的话，**Agent 查到的空看起来正好像
/// 「没问题」**——这个项目在「存了却不报」上栽过不止一次。
void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('status_ch');
    await FileTaskRepository(dir).save(RenewTask(
      id: 't1',
      seq: 1,
      name: '片子',
      sourcePath: null,
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 9, 18),
      updatedAt: DateTime.utc(2026, 9, 18),
    ));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Map<String, dynamic>> rowOf() async {
    final out = StringBuffer();
    final code = await runStatusCommand(
        rest: ['t1'], dataDir: dir, json: true, out: out, err: StringBuffer());
    expect(code, 0);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    return (json['tasks'] as List).single as Map<String, dynamic>;
  }

  test('软件自己在跑：status 里说得出来，而且和 Agent 分开两组', () async {
    writeAppBusy(
      dataDir: dir,
      taskId: 't1',
      busy: AgentPresence(
          holder: '软件（分析）', at: DateTime.now(), action: '正在分析原片：打标'),
    );

    final row = await rowOf();
    expect(row['appBusyWith'], '软件（分析）',
        reason: '不报的话，Agent 查到的空看起来正好像「没问题」，'
            '而它紧接着的 analyze 会被劝退——它完全不知道为什么');
    expect(row['appDoingNow'], contains('打标'));
    expect(row['busyWith'], isNull,
        reason: '这不是「另一个 Agent 在跑」，混成一个字段的话，'
            'Agent 分不清该去问人还是去等自己那条命令');
  });

  test('两边同时在跑：两组都报得出来', () async {
    writeAgentPresence(
      dataDir: dir,
      taskId: 't1',
      presence: AgentPresence(
          holder: 'agent:99', at: DateTime.now(), action: '正在给第 3 句配音'),
    );
    writeAppBusy(
      dataDir: dir,
      taskId: 't1',
      busy: AgentPresence(
          holder: '软件（分析）', at: DateTime.now(), action: '正在分析原片'),
    );

    final row = await rowOf();
    expect(row['busyWith'], 'agent:99');
    expect(row['appBusyWith'], '软件（分析）');
  });

  test('都没人在：两组都不出现，不是空字符串', () async {
    final row = await rowOf();
    expect(row.containsKey('busyWith'), isFalse);
    expect(row.containsKey('appBusyWith'), isFalse);
  });
}
