import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/review_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/review/review_receipt.dart';
import 'package:ishkafel/core/storage/ui_wake.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// `ishkafel review` / `review-result` —— 人把关那一环的 CLI 半边。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  RenewTask taskWith({List<UnitReplacement>? replacements}) => RenewTask(
        id: 'r1',
        name: '审核',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 17),
        updatedAt: DateTime.utc(2026, 8, 17),
        units: const [
          SemanticUnit(index: 0, startMs: 0, endMs: 5000, transcript: 'A'),
        ],
        replacements: replacements,
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_review_');
    repo = FileTaskRepository(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('review', () {
    test('写唤醒文件并激活 app——不走 --args，那只在冷启动时生效', () async {
      await repo.save(taskWith(replacements: [
        UnitReplacement.whole(const [101]),
      ]));
      final calls = <List<String>>[];
      final err = StringBuffer();
      final code = await runReviewCommand(
        rest: ['r1'],
        dataDir: dir,
        env: const {},
        err: err,
        run: (bin, args) async {
          calls.add([bin, ...args]);
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(code, 0);
      // 意图在唤醒文件里，open 只负责把 app 带到前台
      expect(calls.single.any((a) => a.contains('--task')), isFalse);
      final wake = consumeUiWake(dir)!;
      expect(wake.taskId, 'r1');
      expect(wake.review, isTrue);
      expect(err.toString(), contains('review-result r1'));
    });

    test('一条候选都没挑时拒绝——拉起空审核页只会让人困惑', () async {
      await repo.save(taskWith());
      final err = StringBuffer();
      final code = await runReviewCommand(
          rest: ['r1'], dataDir: dir, env: const {}, err: err);
      expect(code, exitBadUsage);
      expect(err.toString(), contains('没有可审核的'));
    });

    test('重新审核会清掉上一轮的回执——不清的话取到的是旧结果', () async {
      await repo.save(taskWith(replacements: [
        UnitReplacement.whole(const [101]),
      ]));
      saveReviewReceipt(
          dir,
          'r1',
          ReviewReceipt(
              reviewedAt: DateTime.utc(2026, 8, 16), decisions: const []));

      await runReviewCommand(
        rest: ['r1'],
        dataDir: dir,
        env: const {},
        err: StringBuffer(),
        run: (_, _) async => ProcessResult(0, 0, '', ''),
      );
      expect(readReviewReceipt(dir, 'r1'), isNull);
    });
  });

  group('review-result', () {
    test('还没确认时退出码 3 并说清在等什么', () async {
      final err = StringBuffer();
      final code = await runReviewResultCommand(
          rest: ['r1'], dataDir: dir, err: err);
      expect(code, exitNotFound);
      expect(err.toString(), contains('还没有审核回执'));
    });

    test('有回执时输出保留/剔除统计与逐条决定', () async {
      saveReviewReceipt(
        dir,
        'r1',
        ReviewReceipt(reviewedAt: DateTime.utc(2026, 8, 17), decisions: const [
          ReviewDecision(unit: 0, shot: null, material: 101, keep: true),
          ReviewDecision(unit: 0, shot: null, material: 102, keep: false),
        ]),
      );
      final out = StringBuffer();
      final code = await runReviewResultCommand(
          rest: ['r1'], dataDir: dir, out: out);
      expect(code, 0);
      final json = jsonDecode(out.toString()) as Map;
      expect(json['kept'], 1);
      expect(json['dropped'], 1);
      expect(json['note'], contains('不需要再改方案'));
    });
  });

  test('唤醒文件读到即删——同一条请求只处理一次', () {
    writeUiWake(dir, 'r1', review: true);
    expect(consumeUiWake(dir), isNotNull);
    expect(consumeUiWake(dir), isNull);
  });
}
