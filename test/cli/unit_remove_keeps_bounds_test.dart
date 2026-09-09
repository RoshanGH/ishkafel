import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/unit_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// 删掉手动加的台词语义单元，**不许动别的单元的起止**。
///
/// 2026-09-09 真机：这条路一直走的是空白任务那套（重铺成连续的一条），
/// 于是有原片的任务被删过一次之后，每个单元的起止都被挪了，而单元里的
/// 视觉镜头留在原地。两层坐标各说各话，人后来看到的是：
/// - 合并视觉镜头之后，单元尾部空出一截（镜头轨画到别处去了）
/// - 选中一个镜头去替换，预览跳回 U1·S1
///
/// 这条线钉住起因；`test/core/editing/unit_bounds_repair_test.dart` 钉住
/// 已经坏掉的存档怎么修回来。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  SemanticUnit sourceUnit(int index, int start, int end) => SemanticUnit(
        index: index,
        startMs: start,
        endMs: end,
        transcript: 'u$index',
        shots: [
          Shot(startMs: start, endMs: (start + end) ~/ 2),
          Shot(startMs: (start + end) ~/ 2, endMs: end),
        ],
      );

  RenewTask replaceTask() => RenewTask(
        id: 'r1',
        name: '有原片的任务',
        sourcePath: '/tmp/原片.mp4',
        // **手加的那个夹在中间**：删掉它，重铺就会把后面的整体往前拽，
        // 而后面那个单元里的镜头留在原地。手加的排在末尾时看不出这个 bug
        units: [
          sourceUnit(0, 0, 10000),
          const SemanticUnit(
              index: 1,
              startMs: 10000,
              endMs: 20000,
              transcript: '',
              shots: [],
              hasSource: false),
          sourceUnit(2, 20000, 34000),
        ],
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 9),
        updatedAt: DateTime.utc(2026, 9, 9),
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_unit_rm_');
    repo = FileTaskRepository(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('删掉手加的那个之后，原片单元的起止一毫秒都没动', () async {
    await repo.save(replaceTask());

    final code = await runUnitCommand(
        rest: ['remove', 'r1'], dataDir: dir, unit: 1, out: StringBuffer());
    expect(code, 0);

    final units = (await repo.findById('r1'))!.units!;
    expect(units, hasLength(2));
    expect(units[0].startMs, 0);
    expect(units[0].endMs, 10000);
    expect(units[1].startMs, 20000,
        reason: '重铺成连续的一条会把它拽到 10000，而它的镜头还在 20000——'
            '两层就此对不上');
    expect(units[1].endMs, 34000);
  });

  test('每个单元的镜头照旧首尾相接铺满这个单元', () async {
    await repo.save(replaceTask());
    await runUnitCommand(
        rest: ['remove', 'r1'], dataDir: dir, unit: 1, out: StringBuffer());

    for (final u in (await repo.findById('r1'))!.units!) {
      if (u.shots.isEmpty) continue;
      expect(u.shots.first.startMs, u.startMs, reason: 'U${u.index + 1} 的镜头对不上');
      expect(u.shots.last.endMs, u.endMs, reason: 'U${u.index + 1} 的镜头对不上');
    }
  });

  /// 读档时有一道自愈（[repairUnitBoundsFromShots]），会把挪错的起止按镜头
  /// 修回来——**所以只看读出来的对象是看不出这个 bug 的**，得看盘上写了什么。
  /// 自愈是给已经坏掉的老存档兜底的，不是让新的坏数据可以随便写
  test('盘上写的就得是对的，别指望读档那道自愈兜着', () async {
    await repo.save(replaceTask());
    await runUnitCommand(
        rest: ['remove', 'r1'], dataDir: dir, unit: 1, out: StringBuffer());

    final raw = jsonDecode(File('${dir.path}/tasks/r1.json').readAsStringSync())
        as Map<String, dynamic>;
    final units = (raw['units'] as List).cast<Map<String, dynamic>>();
    expect(units[1]['startMs'], 20000,
        reason: '重铺成连续的一条会把它写成 10000，而它的镜头还在 20000');
    expect(units[1]['endMs'], 34000);
  });

  test('下标要补位——替换方案、配音、配乐都是按下标记的', () async {
    await repo.save(replaceTask());
    await runUnitCommand(
        rest: ['remove', 'r1'], dataDir: dir, unit: 1, out: StringBuffer());

    expect((await repo.findById('r1'))!.units!.map((u) => u.index), [0, 1]);
  });
}
