import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/analysis/audio_extractor.dart';
import '../../core/analysis/scene_detector.dart';
import '../../core/ai/volcano_asr_provider.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/models/export_record.dart';
import '../../core/models/renew_task.dart';
import '../../core/script/script_doc.dart';
import '../../core/subtitle/subtitle_style.dart';
import '../../core/script/script_export.dart';
import '../../core/script/shot_allocation.dart';
import '../../core/script/script_service_wiring.dart';
import '../../core/script/script_transcriber.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_media.dart';
import '../../core/storage/task_seq.dart';
import '../../core/jianying/jianying_writer.dart';
import '../../core/jianying/jianying_plan.dart';
import '../voice_baseline.dart';
import '../agent_stage.dart';
import '../agent_lock_holder.dart';
import '../cli_output.dart';
import '../lock_yield.dart';
import 'analyze_command.dart' show loadCliCredentials;

/// 脚本成片这条线的**执行类**命令：建任务、提取脚本、配音、导出。
///
/// 与「判断类」（挑镜头、断句）的区别在于这里没有可选项——ASR 和 TTS 的输出
/// 无法验证，所以不外包（spec 第三节）；这些命令只是让 Agent 能把整条链
/// 从头跑到尾，不必回头找人点界面。
///
/// 每一步都上报在场状态：人在界面上看得见它在干什么。

/// `ishkafel script new <名字> [--project <id>]`
Future<int> runScriptNewCommand({
  required List<String> rest,
  required Directory dataDir,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel script new <任务名>');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final seq = await nextTaskSeq(repository);
  final now = DateTime.now();
  final task = RenewTask(
    id: 'sc${now.millisecondsSinceEpoch.toRadixString(36)}',
    seq: seq,
    name: rest.first,
    sourcePath: null,
    script: ScriptDoc.empty(),
    status: RenewTaskStatus.ready,
    createdAt: now,
    updatedAt: now,
  );
  await repository.save(task);
  emitJson({'ok': true, 'taskId': task.id, 'seq': seq, 'name': task.name},
      out: out);
  return 0;
}

/// `ishkafel script extract <task> <video>` —— 从参考片提取脚本。
///
/// ASR **不外包**：时间戳偏 200ms 就足以毁掉整条链（切分错位、镜头对不上），
/// 而这个错不会报错，一路静默到看成片才发现（spec 第三节）
Future<int> runScriptExtractCommand({
  required List<String> rest,
  required Directory dataDir,
  String? holder,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.length < 2) {
    sink.writeln('用法：ishkafel script extract <任务 id> <参考视频路径>');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest[0]);
  if (task == null) {
    sink.writeln('没有这个任务：${rest[0]}');
    return exitNotFound;
  }
  final video = rest[1];
  if (!File(video).existsSync()) {
    sink.writeln('找不到这个视频文件：$video');
    return exitBadUsage;
  }
  final credentials = loadCliCredentials(dataDir);
  if (credentials.speechAppId.isEmpty) {
    sink.writeln('缺少语音凭据，识别不了台词。把 speech_app_id / '
        'speech_access_token 放到 <数据目录>/credentials 或 ./.secrets');
    return exitEnv;
  }
  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!await acquireYieldingFromUi(
      lock: lock,
      holder: holder ?? agentLockHolder,
      dataDir: dataDir,
      taskId: task.id)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务');
    return exitLocked;
  }
  final heartbeat =
      Timer.periodic(const Duration(seconds: 20), (_) => lock.heartbeat(holder ?? agentLockHolder));
  writeAgentPresence(
      dataDir: dataDir,
      taskId: task.id,
      presence: AgentPresence(
          holder: holder ?? agentLockHolder, at: DateTime.now(), action: '正在识别参考片的台词'));
  try {
    final transcriber = ScriptTranscriber(
      audio: AudioExtractor(run: const ResolvingProcessRunner().call),
      asr: VolcanoAsrProvider(
        appId: credentials.speechAppId,
        accessToken: credentials.speechAccessToken,
      ),
      scenes: SceneDetector(run: const ResolvingProcessRunner().call),
      workDir: Directory(p.join(dataDir.path, 'analysis_work', task.id)),
    );
    final lines = await transcriber.extract(video, onStage: (stage) {
      writeAgentPresence(
          dataDir: dataDir,
          taskId: task.id,
          presence: AgentPresence(
              holder: holder ?? agentLockHolder, at: DateTime.now(), action: stage.label));
      sink.writeln('· ${stage.label}');
    });
    final doc = ScriptDoc(lines,
        subtitle: task.script?.subtitle ?? const SubtitleStyle(),
        refVideoPath: video);
    await repository.save(task.copyWith(script: doc));
    emitJson({'ok': true, 'taskId': task.id, 'lines': lines.length}, out: out);
    return 0;
  } on ScriptTranscribeException catch (e) {
    sink.writeln(e.message);
    return exitFailed;
  } finally {
    heartbeat.cancel();
    clearAgentPresence(dataDir: dataDir, taskId: task.id);
    lock.release(holder ?? agentLockHolder);
  }
}

/// `ishkafel script voice <task> [--line <行号>] [--voice <音色 id>]`
///
/// TTS **不外包**（音频无法验证），但生成时会自查：念重复、没念完、语速离谱
/// 的自动重来一次，两次都岔就点名（见 voice_qc.dart）
Future<int> runScriptVoiceCommand({
  required List<String> rest,
  required Directory dataDir,
  int? line,
  String? voiceId,
  String? holder,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel script voice <任务 id> [--line <行号>] '
        '[--voice <音色 id>]');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  var doc = task.script;
  if (doc == null) {
    sink.writeln('「${task.name}」不是脚本成片任务');
    return exitBadUsage;
  }
  final factory = defaultLineVoiceFactory(loadCliCredentials(dataDir), dataDir);
  if (factory == null) {
    sink.writeln('缺少语音凭据，配不了音。把 speech_app_id / '
        'speech_access_token 放到 <数据目录>/credentials 或 ./.secrets');
    return exitEnv;
  }
  // 音色先定下来再说。**不定就不开工**——音色不对整片得重配，
  // 而每一句都是花钱的（界面早就这么卡了，CLI 这边一直在撞运气）
  final baseline = resolveVoiceBaseline(doc: doc, explicit: voiceId);
  if (baseline.reject != null) {
    sink.writeln(baseline.reject!);
    return exitBadUsage;
  }
  final defaultVoice = baseline.voiceId!;
  // --voice 给的音色**写成本片基调，不钉进每一行**。钉进行里的话，
  // 以后换基调那些行不认，混出一条前后音色不一样的片子
  if (voiceId != null && doc.defaultVoiceId != voiceId) {
    doc = doc.withDefaultVoiceId(voiceId);
  }

  // 指定行就只配那一行，否则把所有还没配音/配音过期的都补上。
  // **拿 doc.voiceStateOf 判，不是 line.voiceState**：后者看不见基调变化，
  // 于是「改完基调重新生成」这件事在命令行上根本触发不了
  final targets = <int>[
    for (var i = 0; i < doc.lines.length; i++)
      if (doc.lines[i].type == ScriptLineType.voiced &&
          (line == null
              ? doc.voiceStateOf(doc.lines[i]) != LineVoiceState.fresh
              : i == line - 1))
        i,
  ];
  if (targets.isEmpty) {
    emitJson({'ok': true, 'generated': 0, 'note': '没有需要配音的行'}, out: out);
    return 0;
  }

  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!await acquireYieldingFromUi(
      lock: lock,
      holder: holder ?? agentLockHolder,
      dataDir: dataDir,
      taskId: task.id)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务');
    return exitLocked;
  }
  final heartbeat =
      Timer.periodic(const Duration(seconds: 20), (_) => lock.heartbeat(holder ?? agentLockHolder));
  final service = factory(task);
  final failed = <String>[];
  try {
    for (var k = 0; k < targets.length; k++) {
      final i = targets[k];
      final lineId = doc!.lines[i].id;
      writeAgentPresence(
        dataDir: dataDir,
        taskId: task.id,
        presence: AgentPresence(
          holder: holder ?? agentLockHolder,
          at: DateTime.now(),
          action: '正在给第 ${i + 1} 句配音（${k + 1}/${targets.length}）',
          focus: AgentFocus(lineIndex: i, panel: AgentPanel.voice),
        ),
      );
      final target = doc.lines[i];
      try {
        final vo = await service.generate(
          lineId: lineId,
          text: target.text,
          voiceId: doc.voiceIdOf(target) ?? defaultVoice,
          speechRate: doc.speechRateOf(target),
        );
        doc = doc.setVoiceoverById(lineId, vo);
        // 配音时长是这一行的根：根变了，镜头分配跟着重算
        final updated = doc.lines.firstWhere((l) => l.id == lineId);
        if (updated.shots.isNotEmpty) {
          doc = doc.setShotsById(
              lineId,
              ShotAllocation.fillBySlowdown(
                  reallocShots(updated, updated.shots),
                  vo.durationMs));
        }
        await repository.save(task.copyWith(script: doc));
        sink.writeln('· 第 ${i + 1} 句好了（${vo.durationMs}ms）');
      } catch (e) {
        failed.add('第 ${i + 1} 句：$e');
      }
    }
    emitJson({
      'ok': failed.isEmpty,
      'generated': targets.length - failed.length,
      if (failed.isNotEmpty) 'failed': failed,
    }, out: out);
    return failed.isEmpty ? 0 : exitFailed;
  } finally {
    heartbeat.cancel();
    clearAgentPresence(dataDir: dataDir, taskId: task.id);
    lock.release(holder ?? agentLockHolder);
  }
}

/// `ishkafel script export <task> [--out <目录>]`
Future<int> runScriptExportCommand({
  required List<String> rest,
  required Directory dataDir,
  String? outputDir,
  String? holder,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel script export <任务 id> [--out <目录>]');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final doc = task.script;
  if (doc == null) {
    sink.writeln('「${task.name}」不是脚本成片任务');
    return exitBadUsage;
  }
  final dir = outputDir ??
      p.join(Platform.environment['HOME'] ?? '.', 'Desktop', 'ishkafel-脚本成片');
  final stamp = DateTime.now();
  final name = '#${task.seq ?? ''}_'
      '${stamp.month.toString().padLeft(2, '0')}'
      '${stamp.day.toString().padLeft(2, '0')}_'
      '${stamp.hour.toString().padLeft(2, '0')}'
      '${stamp.minute.toString().padLeft(2, '0')}.mp4';

  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!await acquireYieldingFromUi(
      lock: lock,
      holder: holder ?? agentLockHolder,
      dataDir: dataDir,
      taskId: task.id)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务');
    return exitLocked;
  }
  final heartbeat =
      Timer.periodic(const Duration(seconds: 20), (_) => lock.heartbeat(holder ?? agentLockHolder));
  try {
    final runner = ScriptExportRunner(
      workDir: Directory(p.join(dataDir.path, 'script_export', task.id)),
      localPathOf: (id) {
        return TaskMedia(dataDir: dataDir, taskId: task.id).localMaterial(id);
      },
      localSourceOk: (path) => File(path).existsSync(),
      run: const ResolvingProcessRunner().call,
    );
    final output = await runner.export(
      doc: doc,
      outPath: p.join(dir, name),
      onProgress: (progress) {
        writeAgentPresence(
            dataDir: dataDir,
            taskId: task.id,
            presence: AgentPresence(
                holder: holder ?? agentLockHolder,
                at: DateTime.now(),
                action: '正在导出：${progress.step}'));
      },
    );
    await repository.save(task.copyWith(exports: [
      ...task.exports,
      ExportRecord(
          at: DateTime.now(), total: 1, succeeded: 1, outputDir: dir),
    ]));
    emitJson({'ok': true, 'output': output}, out: out);
    return 0;
  } on ScriptExportException catch (e) {
    sink.writeln(e.message);
    return exitFailed;
  } finally {
    heartbeat.cancel();
    clearAgentPresence(dataDir: dataDir, taskId: task.id);
    lock.release(holder ?? agentLockHolder);
  }
}

/// `ishkafel script jianying <task>` —— 把这条片子写成一份**剪映草稿**。
///
/// 界面上那个「剪映」按钮做的是同一件事。Agent 也要能做：人说「给我导进
/// 剪映我自己精修」时，它不该回一句「只能你自己去点」。
///
/// **不拉起剪映**：剪映没有给外部程序「打开指定草稿」的通道（实测详见
/// jianying_writer 的注释）。所以返回的是**草稿名**——人去剪映草稿列表里
/// 按这个名字打开。
Future<int> runScriptJianyingCommand({
  required List<String> rest,
  required Directory dataDir,
  String? holder,
  bool? visual,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel script jianying <任务 id>');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final doc = task.script;
  if (doc == null) {
    sink.writeln('「${task.name}」不是脚本成片任务');
    return exitBadUsage;
  }

  // 生成草稿不写任务数据，但要占锁：素材落地期间人在界面上换素材，
  // 草稿会拿到一半新一半旧
  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!await acquireYieldingFromUi(
      lock: lock,
      holder: holder ?? agentLockHolder,
      dataDir: dataDir,
      taskId: task.id)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，先等它');
    return exitLocked;
  }
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder ?? agentLockHolder,
  );
  await stage.begin('正在生成剪映草稿',
      focus: const AgentFocus(module: 'director'));
  final heartbeat =
      Timer.periodic(const Duration(seconds: 20), (_) => lock.heartbeat(holder ?? agentLockHolder));
  try {
    final writer = JianyingWriter(
      sourceOf: (shot) {
        final local = shot.localSource;
        if (local != null && File(local).existsSync()) return local;
        return TaskMedia(dataDir: dataDir, taskId: task.id)
            .localMaterial(shot.materialId);
      },
      voiceOf: (line) {
        final path = line.voiceover?.audioPath;
        return path != null && File(path).existsSync() ? path : null;
      },
      bgmOf: (id) =>
          TaskMedia(dataDir: dataDir, taskId: task.id).localBgm(id),
    );
    final result = await writer.write(
      doc,
      taskName: '#${task.seq ?? ''} ${task.name}'.trim(),
      onProgress: (done, total, what) {
        sink.writeln('[$done/$total] $what');
        stage.heartbeat('生成剪映草稿：$what',
            focus: const AgentFocus(module: 'director'));
      },
    );
    emitJson({
      'ok': true,
      'draftName': result.name,
      'draftDir': result.folder,
      'totalMs': result.totalMs,
      'materialCount': result.materialCount,
      // 有话要说就说出来（比如某几镜的素材还没就绪、被跳过了）
      if (result.notes.isNotEmpty) 'notes': result.notes,
      // 剪映不认外部的「打开这份草稿」请求，只能让人自己去列表里点
      'next': '去剪映的草稿列表里打开「${result.name}」'
          '（剪映启动时会扫一遍，运行中每隔几分钟扫一次；'
          '没看到就重启一下剪映）',
    }, out: out);
    return 0;
  } on JianyingPlanException catch (e) {
    sink.writeln(e.message);
    return exitBadUsage;
  } catch (e) {
    sink.writeln('生成剪映草稿失败：$e');
    return exitFailed;
  } finally {
    heartbeat.cancel();
    stage.end();
    lock.release(holder ?? agentLockHolder);
  }
}
