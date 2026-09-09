import 'dart:io';

import '../../core/audio/voice_plan.dart';
import '../../core/audio/voice_catalog.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_seq.dart';
import '../agent_lock_holder.dart';
import '../../core/audio/voice_swap_job.dart';
import '../../core/storage/agent_presence.dart';
import '../agent_stage.dart';
import 'analyze_command.dart';
import '../cli_output.dart';

/// `ishkafel voice <任务> --units 0,2 --voice <音色 id>`
///
/// 替换裂变用原声，但**支持换音色**——界面上有「换音色」和「生成配音」，
/// 导出时还会拦下「选了音色却没生成配音」。整条链人一直能走，
/// Agent 一步都走不了（脚本成片那条线有 `script voice`，这条线一直没有）。
///
/// **只落方案，不立刻合成**：合成要走云端、每句几秒，人往往先把几句都定好
/// 再统一生成。跟界面上是同一个语义。
/// `ishkafel voice generate <任务>`：把已经定好的换音色方案真正合成。
///
/// 与选音色分开是刻意的（跟界面上同一个语义）：选是即时的，合成要走云端、
/// 每句几秒还按字符计费，人往往先把几句都定好再统一生成。
///
/// **只选不生成的话导出会被拦下**——那道拦截一直有，而 Agent 以前根本
/// 没有办法生成，等于被那道拦截堵死。
Future<int> runVoiceGenerateCommand({
  required List<String> rest,
  required Directory dataDir,
  String? holder,
  bool? visual,
  StringSink? out,
  StringSink? err,
  VoiceSwapFactory? factory,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel voice generate <任务 id>');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  if (task.voices.isEmpty) {
    sink.writeln('这条任务没有选过音色，没什么可生成的。'
        '先 ishkafel voice <任务> --units 0,2 --voice <音色 id>');
    return exitBadUsage;
  }
  final units = task.units ?? const [];
  final make = factory ??
      defaultVoiceSwapFactory(
          credentials: loadCliCredentials(dataDir), dataDir: dataDir);
  if (make == null) {
    sink.writeln('缺少 AI 凭据，合成不了配音。先跑 ishkafel doctor 看缺什么');
    return exitEnv;
  }
  final job = make(task);
  if (job == null) {
    sink.writeln('「${task.name}」换不了音色——它没有原片，也就没有台词可念');
    return exitBadUsage;
  }

  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  final who = holder ?? agentLockHolder;
  if (!lock.acquire(who)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，先等它');
    return exitLocked;
  }
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
  );
  await stage.begin('正在生成配音',
      focus: const AgentFocus(module: 'workbench'));
  try {
    final results = await job.service.run(
      units: units,
      sentences: task.asrSentences ?? const [],
      plan: task.voices,
      onProgress: (done, total) {
        sink.writeln('[$done/$total] 正在合成');
        stage.heartbeat('正在生成配音 $done/$total',
            focus: const AgentFocus(module: 'workbench'));
      },
    );
    job.outputDir.createSync(recursive: true);
    final written = <String, String>{};
    for (final e in results.entries) {
      final file = job.audioFor(e.key)..writeAsBytesSync(e.value.audio);
      written[e.key] = file.path;
    }
    final failed = job.service.failures;
    emitJson({
      'ok': failed.isEmpty,
      'generated': written.length,
      'audio': {for (final e in written.entries) '${e.key}': e.value},
      // 失败的要点名：不点名的话人不知道该重跑哪几句，
      // 而导出会因为「选了音色没生成」被拦下
      if (failed.isNotEmpty)
        'failed': {for (final e in failed.entries) '${e.key}': e.value},
      'next': failed.isEmpty
          ? '可以导出了'
          : '这几句没合成成功，重跑一次这条命令只会补这几句',
    }, out: out);
    return failed.isEmpty ? 0 : exitFailed;
  } catch (e) {
    sink.writeln('生成配音失败：$e');
    return exitFailed;
  } finally {
    stage.end();
    lock.release(who);
  }
}

Future<int> runVoiceCommand({
  required List<String> rest,
  required Directory dataDir,
  String? units,
  String? voiceId,
  String? holder,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel voice <任务 id> --units 0,2 --voice <音色 id>\n'
        '  不给 --voice 就是看现状；--voice 给空串是把这几句的音色清掉。\n'
        '  有哪些音色：ishkafel voices');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final all = task.units ?? const [];
  if (all.isEmpty) {
    sink.writeln('「${task.name}」还没有台词语义单元——先跑 ishkafel analyze');
    return exitBadUsage;
  }

  // 只看现状
  if (voiceId == null) {
    emitJson({
      'taskId': task.id,
      // 对外照旧说 U1/U2（下标）——那是人和 Agent 说话的方式；
      // 存的是单元自己的身份，两者在这里翻译
      'assigned': [
        for (var i = 0; i < all.length; i++)
          if (task.voices.assignedUnits.contains(all[i].uid))
            {
              'unit': i,
              'voiceId': task.voices.voiceOf(all[i].uid)?.id,
              'voiceName': task.voices.voiceOf(all[i].uid)?.name,
              'transcript': all[i].transcript,
            },
      ],
      'hint': '换音色：ishkafel voice <任务> --units 0,2 --voice <音色 id>。'
          '有哪些音色用 ishkafel voices 看。'
          '换完要 ishkafel voice generate <任务> 真正合成——'
          '只选不生成的话，导出会被拦下',
    }, out: out);
    return 0;
  }

  final targets = <int>[
    for (final piece in (units ?? '').split(',')) ?int.tryParse(piece.trim()),
  ];
  if (targets.isEmpty) {
    sink.writeln('要说清给哪几句换：--units 0,2（下标从 0 起）');
    return exitBadUsage;
  }
  // 越界要点名：静默跳过的话，人以为换了、其实没换
  final bad = targets.where((i) => i < 0 || i >= all.length).toList();
  if (bad.isNotEmpty) {
    sink.writeln('这些单元不存在：${bad.join('、')}（这条片子一共 ${all.length} 个）');
    return exitBadUsage;
  }

  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  final who = holder ?? agentLockHolder;
  if (!lock.acquire(who)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，先等它');
    return exitLocked;
  }
  try {
    final VoicePlan next;
    if (voiceId.trim().isEmpty) {
      next = task.voices.clear([for (final i in targets) all[i].uid]);
    } else {
      final voice = VoiceCatalog.all
          .where((v) => v.ref.id == voiceId.trim())
          .map((v) => v.ref)
          .firstOrNull;
      if (voice == null) {
        sink.writeln('没有这个音色：$voiceId。用 ishkafel voices 看有哪些');
        return exitBadUsage;
      }
      next = task.voices.assign([for (final i in targets) all[i].uid], voice);
    }
    await repository.save(task.copyWith(voices: next, updatedAt: DateTime.now()));
    emitJson({
      'ok': true,
      'assigned': [
        for (var i = 0; i < all.length; i++)
          if (next.assignedUnits.contains(all[i].uid)) i,
      ],
      'next': voiceId.trim().isEmpty
          ? '这几句改回原声了'
          : '换好了，但还没合成。跑 ishkafel voice generate ${task.id} '
              '真正生成配音——只选不生成的话，导出会被拦下',
    }, out: out);
    return 0;
  } finally {
    lock.release(who);
  }
}
