import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/subtitle_command.dart';
import 'package:ishkafel/core/ai/frame_check.dart';
import 'package:ishkafel/core/ai/frame_check_wiring.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

import '../support/seed_task.dart';

/// 造一条「有一镜挑了候选素材、那条候选画面上自带烧录字」的任务，
/// 并把烧字自查结果直接 put 进 [dataDir] 对应的缓存——不用真跑 AI，
/// 只是给 `subtitleShotReport`/`subtitleReport` 一条能查到的数据。
///
/// 用来验证命令层真的把 dataDir 递下去了：漏传的话 burned 那个键会
/// 整个不出现（见 subtitle_view.dart 的「没查」三态），而且没有任何
/// 报错——静默从「有风险」变成「没查」，正是这条测试要拦住的
Future<String> _seedTaskWithBurnedCandidate(Directory dataDir) async {
  final task = RenewTask(
    id: 't_burn',
    name: '测试烧字',
    status: RenewTaskStatus.ready,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    units: const [
      SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '甲乙',
        shots: [Shot(startMs: 0, endMs: 1000), Shot(startMs: 1000, endMs: 2000)],
      ),
    ],
    replacementsByUid: {
      'u0': UnitReplacement.perShot({0: const [7]}),
    },
  );
  await FileTaskRepository(dataDir).save(task);
  frameCheckCacheIn(dataDir)
      .put(7, const FrameCheck(burnedText: ['冰冰凉凉的好舒服呀']));
  return task.id;
}

void main() {
  late Directory dataDir;
  setUp(() => dataDir = Directory.systemTemp.createTempSync('ishkafel_subcmd'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  test('check 只出问题清单，别的什么都不给', () async {
    final id = (await seedTask(dataDir)).id;
    final out = StringBuffer();
    final code =
        await runSubtitleCommand(rest: ['check', id], dataDir: dataDir, out: out);
    expect(code, 0);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json.keys, contains('problems'));
    expect(json.containsKey('shots'), isFalse,
        reason: 'check 是入口，不是报告——给细节就没人看了');
  });

  test('show 出全片报告', () async {
    final id = (await seedTask(dataDir)).id;
    final out = StringBuffer();
    await runSubtitleCommand(rest: ['show', id], dataDir: dataDir, out: out);
    expect((jsonDecode(out.toString()) as Map).keys, contains('shots'));
  });

  test('不给子命令时还是老样子——样式现状', () async {
    final id = (await seedTask(dataDir)).id;
    final out = StringBuffer();
    final code =
        await runSubtitleCommand(rest: [id], dataDir: dataDir, out: out);
    expect(code, 0);
    expect(out.toString(), contains('preset'),
        reason: '老用法不许一声不响地失效');
  });

  test('任务不存在就直说', () async {
    final err = StringBuffer();
    final code = await runSubtitleCommand(
        rest: ['show', '没这条'], dataDir: dataDir, err: err);
    expect(code, exitNotFound);
  });

  test('命令层要把 dataDir 递下去——不然 Agent 永远看不到烧字风险', () async {
    final id = await _seedTaskWithBurnedCandidate(dataDir);
    final out = StringBuffer();
    await runSubtitleCommand(
        rest: ['show', id],
        dataDir: dataDir,
        unitIndex: 0,
        shotIndex: 0,
        out: out);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json.containsKey('burned'), isTrue,
        reason: '漏传 dataDir 的话这里会静默变成「根本没查」，而且没人会发现');
    expect(json['burned'], contains('冰冰凉凉的好舒服呀'));
  });

  test('show 全片那条路也要把 dataDir 递下去', () async {
    // check/show --unit --shot 两条走的都是单镜路径（subtitleShotReport），
    // show 不带 --unit/--shot 时走的是另一处调用（subtitleReport）——
    // 四处传参各自独立，这条专守全片报告那一处
    final id = await _seedTaskWithBurnedCandidate(dataDir);
    final out = StringBuffer();
    await runSubtitleCommand(rest: ['show', id], dataDir: dataDir, out: out);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    final shots = (json['shots'] as List).cast<Map<String, dynamic>>();
    final row = shots.firstWhere((s) => s['at'] == 'U1S1');
    final kinds = (row['problems'] as List?) ?? const [];
    expect(kinds, contains('burnedTextPresent'),
        reason: '四处调用各传各的，漏一处就静默变成「根本没查」，'
            '而这一处是 Agent 扫全片时唯一会走的路');
  });

  test('check 同理：漏传 dataDir 会让烧字风险从问题清单里消失', () async {
    final id = await _seedTaskWithBurnedCandidate(dataDir);
    final out = StringBuffer();
    await runSubtitleCommand(rest: ['check', id], dataDir: dataDir, out: out);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    final problems = (json['problems'] as List).cast<Map<String, dynamic>>();
    final p = problems.firstWhere((p) => p['kind'] == 'burnedTextPresent');
    // 只断言 kind 逮不住「check 里为了拿 note 补的那次 subtitleShotReport
    // 漏传 dataDir」——那一步漏传的话代码会走 fallback，拿全片报告（已经
    // 传了 dataDir）的 kind 拼一条没有 note 的记录，kind 照样在、测试照样
    // 绿。note 只有单镜报告算得出来，断言它的内容才逮得住这一处漏传
    expect(p['note'], isNotNull, reason: 'note 只有单镜报告给得出来');
    expect(p['note'], contains('冰冰凉凉的好舒服呀'));
  });
}
