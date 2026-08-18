import 'dart:io';

import '../../core/review/review_receipt.dart';
import '../../core/storage/ui_wake.dart';
import '../../core/storage/file_task_repository.dart';
import '../cli_output.dart';
import 'open_command.dart';

/// `ishkafel review <task>` —— 把 app 拉起来进**审核模式**，人过一遍
/// 挑好的候选、勾选去留、确认。
///
/// 这是「Agent 干活 → 人把关 → 导出」闭环里人把关那一环。审核界面由软件
/// 提供而不是 Agent 现造：剔除逻辑是固定的、播放的是本地落好的素材
/// （看到的就是要交付的）。
///
/// **审核完一切回到主流程**：人确认后剔除已落进任务，`ishkafel task <id>`
/// 里的方案就是最终结果——没有回执要取。人确认没确认由人告诉你；
/// 等不等、等多久是你和用户之间的策略，软件不当流程裁判。
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

  // 意图走唤醒文件（见 ui_wake.dart）：--args 只在冷启动生效，
  // app 已经在跑时会被静默丢弃
  writeUiWake(dataDir, id, review: true);
  final appPath =
      (env ?? Platform.environment)['ISHKAFEL_APP'] ?? defaultAppPath;
  final exec = run ?? Process.run;
  final result = await exec('open', ['-a', appPath]);
  if (result.exitCode != 0) {
    sink.writeln('打不开 app（$appPath）：${'${result.stderr}'.trim()}');
    return exitEnv;
  }
  sink.writeln('审核界面已打开（${items.length} 条候选待审）。'
      '等用户告诉你继续；确认后 ishkafel task $id 里的方案就是审核后的最终结果');
  return 0;
}
