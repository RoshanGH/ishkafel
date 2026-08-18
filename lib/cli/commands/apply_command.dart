import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../app/service_wiring.dart';
import '../../core/models/renew_task.dart';
import '../external_steps.dart';
import '../task_view.dart';
import '../todo_view.dart';
import 'analyze_command.dart';
import '../cli_output.dart';
import '../plan_submission.dart';

/// `ishkafel apply plans <task> --file <json>`（也支持从 stdin 读）
///
/// 收下 Agent 提交的方案列表，**过校验**之后落盘，供 `export` 使用。
///
/// 校验不过就整批拒绝并一次点全所有问题——让它改一个提交一次是在浪费双方
/// 的时间。外包出去的是「判断」，不是「数据结构的定义权」（spec 第三节）。
Future<int> runApplyCommand({
  required List<String> rest,
  required Directory dataDir,
  String? file,
  String holder = 'agent',
  Future<String> Function()? readStdin,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.length < 2) {
    sink.writeln('用法：ishkafel apply plans|segment|tags <任务 id> --file <x.json>');
    return exitBadUsage;
  }
  final what = rest.first;
  const supported = {'plans', 'segment', 'tags'};
  if (!supported.contains(what)) {
    sink.writeln('认不出「$what」。可用：${supported.join(' / ')}');
    return exitBadUsage;
  }
  final id = rest[1];

  final repository = FileTaskRepository(dataDir);
  final task = await repository.findById(id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }

  // 别人正持着锁就不写——两边同时写会互相覆盖，而且悄无声息
  final lock = TaskLockFile(dataDir: dataDir, taskId: id);
  if (!lock.acquire(holder)) {
    final current = lock.read();
    sink.writeln('${current?.holder ?? '别人'} 正在操作这个任务，写不进去。'
        '等它结束，或在 app 里强制接管');
    return exitLocked;
  }

  try {
    return await _applyWithLock(
      what: what,
      id: id,
      task: task,
      file: file,
      readStdin: readStdin,
      dataDir: dataDir,
      repository: repository,
      sink: sink,
      out: out,
    );
  } finally {
    // 命令跑完立刻还锁。不还的话要等心跳超时 60 秒，这期间人在 app 里
    // 打开这个任务只能看不能改，还不知道为什么
    lock.release(holder);
  }
}

Future<int> _applyWithLock({
  required String what,
  required String id,
  required RenewTask task,
  required String? file,
  required Future<String> Function()? readStdin,
  required Directory dataDir,
  required FileTaskRepository repository,
  required StringSink sink,
  required StringSink? out,
}) async {
  final String raw;
  try {
    raw = file == null
        ? await (readStdin ?? _readStdin)()
        : File(file).readAsStringSync();
  } catch (e) {
    sink.writeln('读不到方案文件：$e');
    return exitBadUsage;
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (e) {
    sink.writeln('提交的内容不是合法的 JSON：$e');
    return exitBadUsage;
  }

  if (what == 'segment') {
    return _applySegment(
        decoded, task, dataDir, repository, sink, out ?? stdout);
  }
  if (what == 'tags') {
    return _applyTags(decoded, task, dataDir, repository, sink, out ?? stdout);
  }

  final validation = parsePlans(decoded, task);
  if (!validation.ok) {
    for (final problem in validation.errors) {
      sink.writeln('· $problem');
    }
    return exitBadUsage;
  }

  _writePlans(dataDir, id, raw);
  // 同步投影成任务的替换现状：审核页读的是它——不投影的话，
  // 纯 CLI 流程里 `ishkafel review` 永远无东西可审（真机踩过）
  await repository.save(task.copyWith(
      replacements:
          projectPlansToReplacements(validation.plans, task.units ?? const [])));
  emitJson({
    'ok': true,
    'plans': [
      for (final plan in validation.plans)
        {'name': plan.name, 'units': plan.units.length},
    ],
  }, out: out);
  return 0;
}

/// 收下切分，组装成单元、落库，并把下一件待办交出去（如果还有）。
///
/// 这里只做**组装**，不做判断——怎么分组是调用方决定的，我们负责把它变成
/// 帧对齐的、和镜头切点吸附好的单元。
Future<int> _applySegment(
  Object? decoded,
  RenewTask task,
  Directory dataDir,
  FileTaskRepository repository,
  StringSink err,
  StringSink out,
) async {
  final state = readAnalysisState(dataDir, task.id);
  if (state == null) {
    err.writeln('没有待处理的分析状态。先跑 ishkafel analyze ${task.id} --external=segment');
    return exitNotFound;
  }

  final parsed = parseSegments(decoded, state.prepared.sentences);
  if (parsed.errors.isNotEmpty) {
    for (final problem in parsed.errors) {
      err.writeln('· $problem');
    }
    return exitBadUsage;
  }

  final credentials = loadCliCredentials(dataDir);
  final pipeline = buildAnalysisPipeline(credentials, dataDir);
  if (pipeline == null) {
    err.writeln('缺少 AI 凭据，无法组装单元');
    return 1;
  }

  final units = pipeline.assemble(
      task: task, drafts: parsed.drafts, prepared: state.prepared);
  final ready = task.copyWith(
    units: units,
    status: RenewTaskStatus.ready,
    asrSentences: state.prepared.sentences,
    vocalsPath: state.prepared.vocalsPath,
    backgroundPath: state.prepared.backgroundPath,
  );
  await repository.save(ready);

  final stillPending = {...state.pending}..remove(ExternalStep.segment);
  saveAnalysisState(dataDir, task.id,
      AnalysisState(prepared: state.prepared, pending: stillPending));

  // 还欠打标就把下一件待办交出去；否则走内置打标收尾
  if (stillPending.contains(ExternalStep.tag)) {
    emitJson(
      tagTodo(
        task.id,
        ready,
        unitVocabulary: await vocabularyFor(ready.unitTagGroups),
        shotVocabulary: await vocabularyFor(ready.shotTagGroups),
      ),
      out: out,
    );
    return 0;
  }

  err.writeln('切分已应用（${units.length} 个单元），开始内置打标');
  final tagged = await pipeline.tagging.tag(ready, units);
  final done = ready.copyWith(units: tagged);
  await repository.save(done);
  clearAnalysisState(dataDir, task.id);
  emitJson(taskToJson(done), out: out);
  return 0;
}

/// 收下标签并落库。标签必须在受控词表内——词表外的一律拒绝，不做近似匹配
Future<int> _applyTags(
  Object? decoded,
  RenewTask task,
  Directory dataDir,
  FileTaskRepository repository,
  StringSink err,
  StringSink out,
) async {
  final units = task.units;
  if (units == null) {
    err.writeln('这个任务还没有单元，先应用切分');
    return exitNotFound;
  }

  final parsed = parseTags(
    decoded,
    units,
    unitVocabulary: (await vocabularyFor(task.unitTagGroups)).toSet(),
    shotVocabulary: (await vocabularyFor(task.shotTagGroups)).toSet(),
  );
  if (parsed.errors.isNotEmpty) {
    for (final problem in parsed.errors) {
      err.writeln('· $problem');
    }
    return exitBadUsage;
  }

  final done = task.copyWith(units: parsed.units);
  await repository.save(done);
  clearAnalysisState(dataDir, task.id);
  emitJson(taskToJson(done), out: out);
  return 0;
}

/// 方案落在任务目录旁边：`<dataDir>/plans/<taskId>.json`。
///
/// 不塞进任务 JSON：那份是 GUI 也在写的，两边同时改一个文件的不同部分
/// 只会把冲突变复杂。方案是 Agent 这条路独有的产物，单独放。
void _writePlans(Directory dataDir, String taskId, String raw) {
  final file = File(p.join(dataDir.path, 'plans', '$taskId.json'));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(raw);
}

/// 读回已提交的方案；没有就返回 null
String? readSubmittedPlans(Directory dataDir, String taskId) {
  final file = File(p.join(dataDir.path, 'plans', '$taskId.json'));
  return file.existsSync() ? file.readAsStringSync() : null;
}

Future<String> _readStdin() async =>
    await stdin.transform(utf8.decoder).join();
