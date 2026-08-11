import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/audio/bgm_cache_factory.dart';
import '../../core/export/export_runner.dart';
import '../../core/ffmpeg/ffprobe_service.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/miaoa/material_downloader.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_locator.dart';
import '../../core/models/export_record.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../cli_output.dart';
import '../plan_submission.dart';
import 'apply_command.dart';

/// `ishkafel export <task> [--out <目录>]`
///
/// 按 `apply plans` 提交的方案**逐条导出**，不做笛卡尔积。
///
/// **先说代价、但不设闸门**：会导几条、大概多久，如实输出；要不要继续是
/// 调用方的判断——我是工具，你来调用我（spec 第一节）。
Future<int> runExportCommand({
  required List<String> rest,
  required Directory dataDir,
  String? outputDir,
  String holder = 'agent',
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel export <任务 id> [--out <目录>]');
    return exitBadUsage;
  }
  final id = rest.first;

  final repository = FileTaskRepository(dataDir);
  final task = await repository.findById(id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  final units = task.units;
  if (units == null) {
    sink.writeln('这个任务还没分析完，没法导出');
    return exitNotFound;
  }

  final raw = readSubmittedPlans(dataDir, id);
  if (raw == null) {
    sink.writeln('还没有提交方案。先跑 ishkafel apply plans $id --file <方案.json>');
    return exitNotFound;
  }
  final validation = parsePlans(jsonDecode(raw), task);
  if (!validation.ok) {
    // 提交时校验过一次，这里再过一遍——中间任务可能被改过（比如切分变了）
    sink.writeln('已提交的方案对不上现在的任务了：');
    for (final problem in validation.errors) {
      sink.writeln('· $problem');
    }
    return exitBadUsage;
  }

  final lock = TaskLockFile(dataDir: dataDir, taskId: id);
  if (!lock.acquire(holder)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，导不了');
    return exitLocked;
  }

  final dest = Directory(outputDir ??
      p.join(Platform.environment['HOME'] ?? '.', 'Desktop', 'ishkafel-$id'));
  final combos = [
    for (var i = 0; i < validation.plans.length; i++)
      toCombination(validation.plans[i], units, index: i),
  ];

  // 代价先说清楚——但不拦。要不要继续是调用方的判断
  sink.writeln('将导出 ${combos.length} 条到 ${dest.path}');

  final runner = ExportRunner(
    run: const ResolvingProcessRunner().call,
    workDir: Directory(p.join(dataDir.path, 'export_work', id)),
    resolveBgm: bgmCache(dataDir).fetch,
    probeDurationMs: (path) async =>
        (await FfprobeService(run: const ResolvingProcessRunner().call)
                .probe(path))
            .duration
            .inMilliseconds,
    fetchMaterial: MaterialDownloader(
      content: MiaoaContentService(binary: resolveMiaoaBinary()),
      cacheDir: Directory(p.join(dataDir.path, 'material_cache')),
    ).fetch,
  );

  final outcomes = await runner.exportCombinations(
    combos: combos,
    sourcePath: task.sourcePath,
    units: units,
    replacements: task.replacements ?? const [],
    outputDir: dest,
    bgm: task.bgm,
    vocalsPath: task.vocalsPath,
    onProgress: (done, total, what) =>
        sink.writeln('[$done/$total] $what'),
  );

  final succeeded = outcomes.where((o) => o.failure == null).length;
  // 导出历史进任务：人在 app 里要能看到「哪天导了几条、在哪儿」
  await repository.save(task.copyWith(exports: [
    ...task.exports,
    ExportRecord(
      at: DateTime.now(),
      total: outcomes.length,
      succeeded: succeeded,
      outputDir: dest.path,
    ),
  ]));
  lock.release(holder);

  emitJson({
    'outputDir': dest.path,
    'total': outcomes.length,
    'succeeded': succeeded,
    'results': [
      for (var i = 0; i < outcomes.length; i++)
        {
          'name': validation.plans[i].name,
          'path': outcomes[i].path,
          'failure': outcomes[i].failure,
        },
    ],
  }, out: out);
  // 有失败的就非零退出：调用方不该靠解析 JSON 才发现出了问题
  return succeeded == outcomes.length ? 0 : 1;
}
