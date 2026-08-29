import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/bgm_command.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// 界面上能给一段单元铺配乐、改区间、删掉、调音量——**整套 Agent 一个都做不了**。
/// 而配乐是进成片的东西（导出会混进去），不是可有可无的装饰。
///
/// 脚本成片那条线有 `script bgm-candidates` 和 `script apply bgm`，
/// 替换裂变这条线一直没有。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  SemanticUnit unit(int i) => SemanticUnit(
      index: i, startMs: i * 5000, endMs: i * 5000 + 5000, transcript: '第 $i 句');

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('bgm');
    repo = FileTaskRepository(dir);
    await repo.save(RenewTask(
      id: 't1',
      name: '片子',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      units: [unit(0), unit(1), unit(2), unit(3)],
    ));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, dynamic> decode(StringBuffer o) =>
      jsonDecode(o.toString()) as Map<String, dynamic>;

  BgmMaterial mat(int id) =>
      BgmMaterial(id: id, name: '曲子$id', durationMs: 60000, previewUrl: null);

  test('给第 1~2 个单元铺一首曲子', () async {
    final out = StringBuffer();
    final code = await runBgmCommand(
      rest: ['t1'],
      dataDir: dir,
      fromUnit: '0',
      toUnit: '1',
      materialIds: '7',
      fetchMaterial: (id) async => mat(id),
      out: out,
      err: StringBuffer(),
    );

    expect(code, 0);
    final plan = (await repo.findById('t1'))!.bgm;
    expect(plan.segments, hasLength(1));
    expect(plan.segments.single.startUnit, 0);
    expect(plan.segments.single.endUnit, 1);
    expect(plan.segments.single.materials.single.id, 7);
    expect(decode(out)['ok'], isTrue);
  });

  test('一段可以选好几首互为备选——导出时按变体轮流用', () async {
    await runBgmCommand(
      rest: ['t1'],
      dataDir: dir,
      fromUnit: '0',
      toUnit: '2',
      materialIds: '7,8,9',
      fetchMaterial: (id) async => mat(id),
      out: StringBuffer(),
      err: StringBuffer(),
    );

    expect((await repo.findById('t1'))!.bgm.segments.single.materials,
        hasLength(3));
  });

  test('删掉一段', () async {
    await runBgmCommand(
        rest: ['t1'], dataDir: dir, fromUnit: '0', toUnit: '1',
        materialIds: '7', fetchMaterial: (id) async => mat(id),
        out: StringBuffer(), err: StringBuffer());

    await runBgmCommand(
        rest: ['t1'], dataDir: dir, fromUnit: '0', remove: true,
        fetchMaterial: (id) async => mat(id),
        out: StringBuffer(), err: StringBuffer());

    expect((await repo.findById('t1'))!.bgm.segments, isEmpty);
  });

  test('不给参数就是看现状', () async {
    final out = StringBuffer();
    await runBgmCommand(
      rest: ['t1'],
      dataDir: dir,
      fetchMaterial: (id) async => mat(id),
      out: out,
      err: StringBuffer(),
    );

    expect(decode(out)['segments'], isEmpty);
    expect('${decode(out)['hint']}', contains('bgm-candidates'),
        reason: '要告诉人上哪儿找曲子');
  });

  test('单元下标越界要点名', () async {
    final err = StringBuffer();
    final code = await runBgmCommand(
      rest: ['t1'],
      dataDir: dir,
      fromUnit: '0',
      toUnit: '99',
      materialIds: '7',
      fetchMaterial: (id) async => mat(id),
      out: StringBuffer(),
      err: err,
    );

    expect(code, isNot(0));
    expect(err.toString(), contains('99'));
  });

  test('曲子取不到就直接说，别铺一段空的进去', () async {
    final err = StringBuffer();
    final code = await runBgmCommand(
      rest: ['t1'],
      dataDir: dir,
      fromUnit: '0',
      toUnit: '1',
      materialIds: '7',
      fetchMaterial: (_) async => null,
      out: StringBuffer(),
      err: err,
    );

    expect(code, isNot(0));
    expect((await repo.findById('t1'))!.bgm.segments, isEmpty);
  });
}
