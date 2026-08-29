import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/apply_command.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:ishkafel/cli/commands/export_command.dart';
import 'package:ishkafel/cli/commands/review_command.dart';
import 'package:ishkafel/cli/plan_submission.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/review/review_receipt.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/core/storage/ui_wake.dart';

/// 「Agent 提交 → 人审核 → Agent 导出」这条产品灵魂线的接通测试。
///
/// 曾经的断裂（审计发现）：apply plans 只落方案文件不写 replacements，
/// 纯 CLI 流程里 review 必然报错；就算审核了，剔除只落 replacements，
/// export 读方案文件——人剔掉的素材会被原样导出去，成片才能发现。
/// 现在：replacements 是唯一真相，方案是提案——提交时投影进任务，
/// 导出时提案对照真相校验。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  RenewTask task() => RenewTask(
        id: 't1',
        name: '流程',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 18),
        updatedAt: DateTime.utc(2026, 8, 18),
        units: const [
          SemanticUnit(index: 0, startMs: 0, endMs: 3000, transcript: 'A', shots: [
            Shot(startMs: 0, endMs: 3000),
          ]),
          SemanticUnit(index: 1, startMs: 3000, endMs: 6000, transcript: 'B', shots: [
            Shot(startMs: 3000, endMs: 4500),
            Shot(startMs: 4500, endMs: 6000),
          ]),
        ],
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_flow_');
    repo = FileTaskRepository(dir);
    await repo.save(task());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const plansJson = '''
  {"plans": [
    {"name": "方案甲", "units": [
      {"unit": 0, "mode": "whole", "material": 101},
      {"unit": 1, "mode": "perShot", "shots": {"0": 201}}
    ]},
    {"name": "方案乙", "units": [
      {"unit": 0, "mode": "whole", "material": 102}
    ]}
  ]}
  ''';

  Future<int> apply() async {
    final f = File('${dir.path}/plans_in.json')..writeAsStringSync(plansJson);
    return runApplyCommand(
      rest: ['plans', 't1'],
      file: f.path,
      dataDir: dir,
      // 测试不打网络：提交方案时会去取素材信息（取段要靠它的时长）
      contentService: MiaoaContentService(
          gateway: MiaoaGateway(
              run: (_, _) async => ProcessResult(1, 0, '{"records":[]}', ''),
              binary: 'miaoa')),
      err: StringBuffer(),
      out: StringBuffer(),
    );
  }

  test('apply plans 把方案投影成任务的替换现状——审核页因此有东西可审', () async {
    expect(await apply(), 0);

    final saved = (await repo.findById('t1'))!;
    final r = saved.replacements!;
    expect(r[0].wholeCandidateIds, [101, 102], reason: '两条方案的候选并集');
    expect(r[1].shotCandidateIds[0], [201]);
    // 投影后 review 命令可达（曾经必然 exit 2）
    final err = StringBuffer();
    final code = await runReviewCommand(
      rest: ['t1'],
      dataDir: dir,
      env: const {},
      appExists: (_) => true,
      err: err,
      run: (_, _) async => ProcessResult(0, 0, '', ''),
    );
    expect(code, 0, reason: '纯 CLI 流程走到审核不该报错：$err');
    expect(consumeUiWake(dir)?.review, isTrue);
  });

  test('人审核剔除后导出：用了被剔素材的方案被点名拦下，不静默导出', () async {
    expect(await apply(), 0);

    // 人在审核里剔掉了 102（方案乙用的那条）
    final saved = (await repo.findById('t1'))!;
    final pruned = applyReviewDecisions(saved.replacements!, const [
      ReviewDecision(unit: 0, shot: null, material: 102, keep: false),
    ]);
    await repo.save(saved.copyWith(replacements: pruned));

    final err = StringBuffer();
    final code = await runExportCommand(
      rest: ['t1'],
      dataDir: dir,
      err: err,
      out: StringBuffer(),
    );
    expect(code, exitBadUsage);
    expect(err.toString(), contains('方案乙'));
    expect(err.toString(), contains('102'));
    expect(err.toString(), contains('审核中被剔除'));
  });

  test('同一单元跨方案模式冲突：提交时整批拒绝', () {
    final validation = parsePlans({
      'plans': [
        {'name': '甲', 'units': [
          {'unit': 0, 'mode': 'whole', 'material': 101},
        ]},
        {'name': '乙', 'units': [
          {'unit': 0, 'mode': 'perShot', 'shots': {'0': 201}},
        ]},
      ],
    }, task());
    expect(validation.ok, isFalse);
    expect(validation.errors.single, contains('既有整体替换又有镜头替换'));
  });

  test('没进过选材流程的任务（replacements 空）：导出不做审核拦截', () {
    final plans = parsePlans({
      'plans': [
        {'name': '甲', 'units': [
          {'unit': 0, 'mode': 'whole', 'material': 101},
        ]},
      ],
    }, task()).plans;
    expect(plansBlockedByReview(plans, null), isEmpty);
    expect(plansBlockedByReview(plans, const []), isEmpty);
  });
}
