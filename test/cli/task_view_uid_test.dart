import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/candidate_context.dart';
import 'package:ishkafel/cli/commands/candidates_command.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// **日志按 uid 记，那 uid 就得在别处对得回下标。**
///
/// `unit_command` 全部十一处、`blank_command` 两处、审片台的 `unit.tags`
/// 都按 `unitUid` 记；`units.edit` / `units.tag.auto` / `units.tag.resume`
/// 的 `changed` / `taggedUnits` 也按 uid 列。而 Agent 读完日志知道
/// 「`k3f9x2…` 这个单元被人改了标签」之后，**得有一条命令把这个 uid 对回
/// 一个下标**，否则日志的可操作性在最后一米断掉。
void main() {
  RenewTask task({String uid = 'u-abc'}) => RenewTask(
        id: 't1',
        name: '测试',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 17),
        updatedAt: DateTime.utc(2026, 9, 17),
        units: [
          SemanticUnit(
            uid: uid,
            index: 0,
            startMs: 0,
            endMs: 1000,
            transcript: 'U1',
            shots: [Shot(startMs: 0, endMs: 1000, tags: ['灶台'])],
          ),
        ],
      );

  test('task --json 的每个单元都带 uid——日志里那个 uid 靠它对回下标', () {
    final unit = (taskToJson(task())['units'] as List).first as Map;
    expect(unit['uid'], 'u-abc',
        reason: '日志全按 unitUid 记，而 task --json 一个 uid 都不报的话，'
            'Agent 读完日志没有任何命令能把它对回一个下标');
  });

  test('挑镜头素材时给的周边事实里也带 uid——那一步正是照着日志去操作的', () {
    final ctx = shotContext(task: task(), unitIndex: 0, shotIndex: 0);
    expect(ctx['unitUid'], 'u-abc',
        reason: 'context 报了 unitIndex（位置）却不报 uid（身份），'
            '而位置一删一挪就变');
  });

  test('candidates 整段模式的 context 同样带 uid', () async {
    final dir = Directory.systemTemp.createTempSync('ishkafel_uid_');
    addTearDown(() => dir.deleteSync(recursive: true));
    await FileTaskRepository(dir).save(task());
    final saved = await FileTaskRepository(dir).findById('t1');
    final service = MiaoaContentService(
        gateway: MiaoaGateway(
      binary: 'miaoa',
      run: (_, __) async => ProcessResult(
          1, 0, jsonEncode({'records': <dynamic>[], 'total': 0}), ''),
    ));
    final out = StringBuffer();
    final code = await runCandidatesCommand(
      rest: ['t1'],
      dataDir: dir,
      unitIndex: 0,
      shotIndex: null,
      keyword: '灶台',
      contentService: service,
      out: out,
      err: StringBuffer(),
    );
    expect(code, 0);
    final ctx = (jsonDecode(out.toString().trim().split('\n').first)
        as Map)['context'] as Map;
    expect(ctx['unitUid'], saved!.units!.first.uid,
        reason: '整段模式的 context 也要给身份，不能只有下标');
  });
}
