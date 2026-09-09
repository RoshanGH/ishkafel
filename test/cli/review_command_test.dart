import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/review_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/ui_wake.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// `ishkafel review` —— 把审核页交到人手上，然后**等人发话**。
///
/// 审核完一切回到主流程：任务里的方案就是最终结果，没有回执要取。
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
          SemanticUnit(uid: 'u0',index: 0, startMs: 0, endMs: 5000, transcript: 'A'),
        ],
        // 测试里的单元身份统一用 'u0'/'u1'…，方案按位置铺到它们身上
        replacementsByUid: {
          for (var i = 0; i < (replacements ?? const []).length; i++)
            'u$i': replacements![i],
        },
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_review_');
    repo = FileTaskRepository(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

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
      appExists: (_) => true,
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
    // 主流程即结果：不引导 Agent 去取什么回执，而是等人发话
    expect(err.toString(), contains('等用户告诉你继续'));
    expect(err.toString(), isNot(contains('review-result')));
  });

  test('一条候选都没挑时拒绝——拉起空审核页只会让人困惑', () async {
    await repo.save(taskWith());
    final err = StringBuffer();
    final code = await runReviewCommand(
        rest: ['r1'], dataDir: dir, env: const {}, err: err);
    expect(code, exitBadUsage);
    expect(err.toString(), contains('没有可审核的'));
  });

  test('没有这个任务时直说', () async {
    final err = StringBuffer();
    final code = await runReviewCommand(
        rest: ['没有'], dataDir: dir, env: const {}, err: err);
    expect(code, exitNotFound);
  });

  test('唤醒文件读到即删——同一条请求只处理一次', () {
    writeUiWake(dir, 'r1', review: true);
    expect(consumeUiWake(dir), isNotNull);
    expect(consumeUiWake(dir), isNull);
  });
}

