import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../app/service_wiring.dart';
import '../../core/models/renew_task.dart';
import '../../core/storage/task_seq.dart';
import '../external_steps.dart';
import '../task_view.dart';
import '../todo_view.dart';
import 'analyze_command.dart';
import '../../core/miaoa/candidate_probe.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/storage/task_media.dart';
import '../agent_lock_holder.dart';
import '../../core/storage/agent_request.dart';
import '../../core/storage/ui_action.dart';
import '../cli_output.dart';
import '../gui_lock_guidance.dart';
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

  /// 测试注入；真机走真实的 miaoa CLI
  MiaoaContentService? contentService,
  CandidateProbe? candidateProbe,
  String? file,
  String? holder,
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
  final task = await resolveTaskRef(repository, id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }

  // 别人正持着锁就不写——两边同时写会互相覆盖，而且悄无声息
  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!lock.acquire(holder ?? agentLockHolder)) {
    final current = lock.read();
    // **界面占着锁不是冲突，是委派的时机**：可视模式要求界面停在这个任务上，
    // 而写入要求界面不能停在这个任务上——于是最该让人看见的一步（提交方案，
    // 成片长什么样就是这一步定的），恰恰因为「人在看」而做不了。
    // 以前给的出路是「让界面挪开」，那等于让人别看。
    if (what == 'plans' && isGuiHolder(current?.holder)) {
      return await _applyPlansViaUi(
        dataDir: dataDir,
        task: task,
        file: file,
        readStdin: readStdin,
        sink: sink,
        out: out,
      );
    }
    sink.writeln(guiLockGuidance(
        holder: current?.holder, taskId: task.id));
    return exitLocked;
  }

  try {
    return await _applyWithLock(
      contentService: contentService,
      candidateProbe: candidateProbe,
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
    lock.release(holder ?? agentLockHolder);
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
  MiaoaContentService? contentService,
  CandidateProbe? candidateProbe,
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
  final replacements =
      projectPlansToReplacements(validation.plans, task.units ?? const []);

  // 顺手把用到的素材连同时长收下来。**取段全靠这个数**：20 秒的素材塞进
  // 0.5 秒的坑位，得先知道它是 20 秒才知道该截一段。界面挑素材时一直在写，
  // 这条路一直不写，于是 Agent 交的方案取段全失效、短镜头照样一串快进
  final used = <int>{
    for (final r in replacements) ...[
      ...r.wholeCandidateIds,
      for (final ids in r.shotCandidateIds.values) ...ids,
    ],
  };
  final content = contentService ?? MiaoaContentService();
  final probe = candidateProbe ??
      CandidateProbe(run: const ResolvingProcessRunner().call);
  final picked = await collectPickedMaterials(
    candidateIds: used,
    known: task.pickedMaterials,
    // 本地已经有这条素材时就不去问名字了：那是给人看的字段，
    // 而每问一次就是一次网络往返（102 条素材实测差出几十秒）
    fetch: (id) async =>
        TaskMedia(dataDir: dataDir, taskId: task.id).localMaterial(id) != null
            ? null
            : content.fetchById(id),
    probeDurationMs: (id) async {
      // 素材已经下到本地就读本地：联网量一条要一秒，一百多条就是一百多秒，
      // 而且网络那条路会失败——失败了取段就退回快进
      final local = TaskMedia(dataDir: dataDir, taskId: task.id)
          .localMaterial(id);
      final m = local != null ? null : await content.fetchById(id);
      final spec = await probe.probe(
          materialId: id, previewUrl: m?.previewUrl, localPath: local);
      return spec?.durationMs ?? 0;
    },
  );

  // 同步投影成任务的替换现状：审核页读的是它——不投影的话，
  // 纯 CLI 流程里 `ishkafel review` 永远无东西可审（真机踩过）
  await repository.save(task.copyWith(
      replacements: replacements, pickedMaterials: picked));
  // 短坑位有几个：取段就是为它们做的，量不到时长时这些镜头会退回快进
  final shortSlots = [
    for (final u in task.units ?? const [])
      for (final shot in u.shots)
        if (shot.endMs - shot.startMs < 1500) shot,
  ].length;
  final notice = trimUnavailableNotice(
    total: picked.length,
    withDuration: picked.where((m) => (m.durationMs ?? 0) > 0).length,
    shortSlots: shortSlots,
  );

  emitJson({
    'ok': true,
    'plans': [
      for (final plan in validation.plans)
        {'name': plan.name, 'units': plan.units.length},
    ],
    'materials': {
      'count': picked.length,
      'withDuration': picked.where((m) => (m.durationMs ?? 0) > 0).length,
    },
    // 影响成片的降级要说出来，不能等人拿到片子才发现有几镜在快放
    if (notice != null) 'notice': notice,
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


/// 请界面去提交方案——**人不用挪开，还能眼看着方案落到时间线上**。
///
/// 与新建任务走同一条委派通道（`AgentRequest`）：下单 → 界面真的去做 →
/// 回执配对。界面那头做的和人自己点是同一件事，不另造一套只读展示。
Future<int> _applyPlansViaUi({
  required Directory dataDir,
  required RenewTask task,
  required String? file,
  required Future<String> Function()? readStdin,
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

  sink.writeln('这个任务的页面正开着，已请界面代为提交——人能看着方案落进去…');
  final id = writeAgentRequest(
    dataDir: dataDir,
    taskId: task.id,
    kind: UiAction.plansApply.wire,
    payload: {'raw': raw},
  );
  final result = await waitForAgentRequest(
      dataDir: dataDir,
      taskId: task.id,
      id: id,
      // 界面要真的把方案投影上去、人还得看得见，给足时间
      timeout: const Duration(seconds: 90));
  if (result == null) {
    // 超时是真失败：活儿没干。报成功的话人会以为方案提交上去了
    sink.writeln('界面没有回应（等了 90 秒）。'
        '让用户看一眼那个页面，或者把界面挪开再跑一次：'
        'ishkafel open <另一个任务 id>');
    return exitEnv;
  }
  if (!result.ok) {
    sink.writeln('没提交成功：${result.message}');
    return exitFailed;
  }
  emitJson({
    'ok': true,
    'via': 'ui',
    'message': result.message,
    ...result.payload,
  }, out: out);
  return 0;
}
