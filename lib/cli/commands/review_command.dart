import 'dart:io';

import '../../core/review/review_receipt.dart';
import '../../core/storage/ui_wake.dart';
import '../../core/storage/file_task_repository.dart';
import '../cli_output.dart';
import 'open_command.dart';

/// `ishkafel review <task>` —— 把 app 拉起来进**审核模式**，人过一遍
/// Agent 挑的候选、勾选去留；`ishkafel review-result <task>` 取回执。
///
/// 这是「Agent 干活 → 人把关 → 导出」闭环里人把关那一环。审核界面由软件
/// 提供而不是 Agent 现造：播放的是本地固定的素材（看到的就是要交付的）、
/// 回执是固定格式（不用每次现编契约）。
///
/// 剔除在人点「确认」那一刻已经由 GUI 落进任务，**Agent 拿回执只是为了
/// 知道结果**（剔了几条、审没审完），不需要也不应该再改一遍方案。
Future<int> runReviewCommand({
  required List<String> rest,
  required Directory dataDir,
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel review <任务 id>');
    return exitBadUsage;
  }
  final id = rest.first;
  final task = await FileTaskRepository(dataDir).findById(id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  final items = collectReviewItems(task.replacements ?? const []);
  if (items.isEmpty) {
    // 没有候选就没有可审的——拉起一个空审核页只会让人困惑
    sink.writeln('$id 还没有挑过任何候选，没有可审核的。'
        '先 apply plans 或在 candidates 里挑，再来审核');
    return exitBadUsage;
  }

  // 审核开始前清掉旧回执：不清的话 review-result 会把上一轮的结果
  // 当成这一轮的交出去
  final stale = reviewReceiptFile(dataDir, id);
  if (stale.existsSync()) stale.deleteSync();

  // 意图走唤醒文件（见 ui_wake.dart）：--args 只在冷启动生效，
  // app 已经在跑时会被静默丢弃
  writeUiWake(dataDir, id, review: true);
  final appPath =
      (env ?? Platform.environment)['ISHKAFEL_APP'] ?? defaultAppPath;
  final exec = run ?? Process.run;
  final result = await exec('open', ['-a', appPath]);
  if (result.exitCode != 0) {
    sink.writeln('打不开 app（$appPath）：${'${result.stderr}'.trim()}');
    return 1;
  }
  sink.writeln('审核界面已打开（${items.length} 条候选待审）。'
      '人确认之后，用 ishkafel review-result $id 取回执');
  return 0;
}

/// `ishkafel review-result <task>` —— 取人审核的回执
Future<int> runReviewResultCommand({
  required List<String> rest,
  required Directory dataDir,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel review-result <任务 id>');
    return exitBadUsage;
  }
  final id = rest.first;
  final receipt = readReviewReceipt(dataDir, id);
  if (receipt == null) {
    sink.writeln('$id 还没有审核回执。人还没在审核界面点「确认」——'
        '等它，或者跑 ishkafel review $id 重新拉起审核');
    return exitNotFound;
  }
  emitJson({
    'reviewedAt': receipt.reviewedAt.toIso8601String(),
    'kept': receipt.keptCount,
    'dropped': receipt.droppedCount,
    'decisions': [for (final d in receipt.decisions) d.toJson()],
    'note': '剔除已在确认那一刻落进任务，不需要再改方案；'
        '接下来可以直接 export',
  }, out: out);
  return 0;
}
