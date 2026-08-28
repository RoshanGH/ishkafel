import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/blank_command.dart';
import 'package:ishkafel/core/editing/blank_unit_ops.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// `ishkafel blank …` —— 空白任务的分子操作。
///
/// 与 GUI 完全同一套规则：保底 4 个分子、删分子时按下标记的东西跟着挪、
/// 标签必须在词表内。两边不一致的话，Agent 做出来的任务人一打开就是错的。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  RenewTask blankTask({int unitCount = 4}) {
    var units = <SemanticUnit>[];
    for (var i = 0; i < unitCount; i++) {
      units = BlankUnitOps.append(units);
    }
    return RenewTask(
      id: 'b1',
      name: '拼片',
      sourcePath: null,
      units: units,
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 13),
      updatedAt: DateTime.utc(2026, 8, 13),
      unitTagGroups: const [TagGroupRef(id: 1, name: '组甲')],
    );
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_blank_cli_');
    repo = FileTaskRepository(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('add 在末尾加一个空分子', () async {
    await repo.save(blankTask());
    final code = await runBlankCommand(
        rest: ['add', 'b1'], dataDir: dir, out: StringBuffer());
    expect(code, 0);
    expect((await repo.findById('b1'))!.units, hasLength(5));
  });

  test('remove 保底 4 个——和 GUI 同一个数', () async {
    await repo.save(blankTask());
    final err = StringBuffer();
    final code = await runBlankCommand(
        rest: ['remove', 'b1'], dataDir: dir, unit: 0, err: err);
    expect(code, exitBadUsage);
    expect(err.toString(), contains('至少要留 4 个'));
  });

  test('remove 掉一个之后下标补位', () async {
    await repo.save(blankTask(unitCount: 5));
    final code = await runBlankCommand(
        rest: ['remove', 'b1'], dataDir: dir, unit: 0, out: StringBuffer());
    expect(code, 0);
    final units = (await repo.findById('b1'))!.units!;
    expect(units, hasLength(4));
    expect(units.map((u) => u.index), [0, 1, 2, 3]);
  });

  test('有原片的任务不许 add/remove——分子是分析切出来的', () async {
    await repo.save(RenewTask(
      id: 'r1',
      name: '拼片',
      sourcePath: '/v/a.mp4',
      units: const [],
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 13),
      updatedAt: DateTime.utc(2026, 8, 13),
    ));
    final err = StringBuffer();
    final code =
        await runBlankCommand(rest: ['add', 'r1'], dataDir: dir, err: err);
    expect(code, exitBadUsage);
    expect(err.toString(), contains('不是空白任务'));
  });

  test('没有这个任务时直说', () async {
    final err = StringBuffer();
    final code =
        await runBlankCommand(rest: ['add', '不存在'], dataDir: dir, err: err);
    expect(code, exitNotFound);
    expect(err.toString(), contains('没有这个任务'));
  });

  test('create 不给标签组直接拒绝——标签是唯一的检索键', () async {
    final err = StringBuffer();
    final code = await runBlankCommand(
        rest: ['create'], dataDir: dir, name: '拼片', err: err);
    expect(code, exitBadUsage);
    expect(err.toString(), contains('--tag-groups'));
  });
}
