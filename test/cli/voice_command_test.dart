import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/voice_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// 替换裂变用原声，但**支持换音色**——界面上有「换音色」按钮和「生成配音」，
/// 导出时还会拦下「选了音色却没生成配音」。整条链人都能走，Agent 一步都走不了。
///
/// 「所有人能干的事，Agent 都要有能力去干」——这条上一直缺着。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  SemanticUnit unit(int i) => SemanticUnit(
      index: i, startMs: i * 2000, endMs: i * 2000 + 2000, transcript: '第 $i 句');

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('voice');
    repo = FileTaskRepository(dir);
    await repo.save(RenewTask(
      id: 't1',
      name: '片子',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      units: [unit(0), unit(1), unit(2)],
    ));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, dynamic> decode(StringBuffer o) =>
      jsonDecode(o.toString()) as Map<String, dynamic>;

  test('给指定单元换音色——只落方案，不立刻合成', () async {
    final out = StringBuffer();
    final code = await runVoiceCommand(
      rest: ['t1'],
      dataDir: dir,
      units: '0,2',
      voiceId: 'zh_female_vv_uranus_bigtts',
      out: out,
      err: StringBuffer(),
    );

    expect(code, 0);
    final saved = (await repo.findById('t1'))!;
    expect(saved.voices.assignedUnits.toSet(), {0, 2});
    expect(decode(out)['next'], contains('generate'),
        reason: '换完要告诉人下一步得生成配音，否则导出会被拦下');
  });

  test('不给 --voice 就是报现状，顺便列出能选的', () async {
    final out = StringBuffer();
    await runVoiceCommand(
      rest: ['t1'],
      dataDir: dir,
      out: out,
      err: StringBuffer(),
    );

    final json = decode(out);
    expect(json['assigned'], isEmpty);
    expect('${json['hint']}', contains('voices'),
        reason: '要告诉人上哪儿看有哪些音色可选');
  });

  test('清掉某几句的音色：--voice 给空串', () async {
    await runVoiceCommand(
        rest: ['t1'], dataDir: dir, units: '0,1', voiceId: 'zh_female_vv_uranus_bigtts',
        out: StringBuffer(), err: StringBuffer());

    await runVoiceCommand(
        rest: ['t1'], dataDir: dir, units: '0', voiceId: '',
        out: StringBuffer(), err: StringBuffer());

    expect((await repo.findById('t1'))!.voices.assignedUnits, [1]);
  });

  test('单元下标越界要点名，别静默跳过', () async {
    final err = StringBuffer();
    final code = await runVoiceCommand(
      rest: ['t1'],
      dataDir: dir,
      units: '0,99',
      voiceId: 'zh_female_vv_uranus_bigtts',
      out: StringBuffer(),
      err: err,
    );

    expect(code, isNot(0));
    expect(err.toString(), contains('99'));
    expect(err.toString(), contains('3'), reason: '要说清一共几个单元');
  });
}
