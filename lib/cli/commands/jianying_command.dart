import 'dart:async';
import 'dart:io';

import '../../core/jianying/jianying_plan.dart' show JianyingPlanException;
import '../../core/jianying/jianying_writer.dart';
import '../../core/jianying/renew_jianying_plan.dart';
import '../../core/miaoa/material_downloader.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/replacement/replacement_plan.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_media.dart';
import '../../core/subtitle/subtitle_style.dart';
import '../agent_stage.dart';
import '../cli_output.dart';
import '../../core/storage/task_seq.dart';

/// `ishkafel jianying <任务>`：把替换裂变的方案写成**一份**剪映工程。
///
/// 与导出 mp4 的区别：不是导出成片，是把「还没定死的选择」原样交给剪映——
/// 同一个位置挑了几条候选就有几条轨，人在剪映里边看边切。成片时间线、
/// 每一镜的倍率、字幕、配乐都摆好，打开就能改。
Future<int> runJianyingCommand({
  required List<String> rest,
  required Directory dataDir,
  String holder = 'Agent',
  bool? visual,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel jianying <任务 id>');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final units = task.units;
  if (units == null || units.isEmpty) {
    sink.writeln('「${task.name}」还没有台词语义单元——'
        '脚本成片任务请用 ishkafel script jianying，'
        '替换裂变任务先跑 ishkafel analyze');
    return exitBadUsage;
  }

  // 占锁：素材落地期间人在界面上换素材，草稿会拿到一半新一半旧
  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!lock.acquire(holder)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，先等它');
    return exitLocked;
  }
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder,
  );
  await stage.begin('正在生成剪映草稿',
      focus: const AgentFocus(module: 'workbench'));
  final heartbeat =
      Timer.periodic(const Duration(seconds: 20), (_) => lock.heartbeat(holder));
  try {
    final media = TaskMedia(dataDir: dataDir, taskId: task.id);

    // **先把素材备齐再算计划**：以前这里只查本地、缺一条就掉头报错，
    // 而报错给的两条出路（「等它下完」「去界面点重试」）Agent 一条都走不了
    // ——没有人在下它，等到天荒地老也不会变。export 一直是自己下的，
    // 这条线漏了这一步（验收 Agent 做了对照实验：同一个任务 export 3/3 全出）
    final downloader = MaterialDownloader(
      content: MiaoaContentService(),
      cacheDir: media.materialsDir,
    );
    final wanted = _neededMaterials(task.replacements ?? const []);
    var fetched = 0;
    for (final id in wanted) {
      if (media.localMaterial(id) == null) {
        sink.writeln('[${fetched + 1}/${wanted.length}] 正在取素材 $id');
        stage.heartbeat('正在取素材（${fetched + 1}/${wanted.length}）',
            focus: const AgentFocus(module: 'workbench'));
        await downloader.fetch(id);
      }
      fetched++;
    }

    final durations = {
      for (final m in task.pickedMaterials) m.id: m.durationMs,
    };
    final plan = buildRenewJianyingPlan(
      units: units,
      replacements: task.replacements ?? const [],
      sourcePath: task.sourcePath ?? '',
      sourceTotalMs: task.videoInfo?.duration.inMilliseconds ?? 0,
      materialOf: media.localMaterial,
      // 量不到时长的按坑位算（倍率 1.0）——宁可不变速，也不拿 0 去做除法
      materialDurationOf: (id) => durations[id] ?? 0,
      sentences: task.asrSentences ?? const [],
      bgm: task.bgm,
      bgmPathOf: media.localBgm,
    );
    final result = await JianyingWriter(sourceOf: (_) => null).writePlan(
      plan,
      taskName: '#${task.seq ?? ''} ${task.name}'.trim(),
      subtitle: task.subtitle,
      onProgress: (done, total, what) {
        sink.writeln('[$done/$total] $what');
        stage.heartbeat('生成剪映草稿：$what',
            focus: const AgentFocus(module: 'workbench'));
      },
    );
    emitJson({
      'ok': true,
      'draftName': result.name,
      'draftDir': result.folder,
      'totalMs': result.totalMs,
      'materialCount': result.materialCount,
      'videoTracks': plan.videoTracks.length,
      if (result.notes.isNotEmpty) 'notes': result.notes,
      'next': '去剪映的草稿列表里打开「${result.name}」'
          '（剪映启动时会扫一遍，运行中每隔几分钟扫一次；没看到就重启一下剪映）。'
          '同一个位置的候选摞成了好几条轨，上面那条盖着下面的——'
          '想用别的候选就把上面那条关掉',
    }, out: out);
    return 0;
  } on JianyingPlanException catch (e) {
    // 不是用法错：命令本身没问题，改多少遍参数都一样。
    // 报成 2 会让照退出码判断的调用方跑去检查参数，走进死胡同
    sink.writeln(e.message);
    return exitFailed;
  } catch (e) {
    sink.writeln('生成剪映草稿失败：$e');
    return exitFailed;
  } finally {
    heartbeat.cancel();
    stage.end();
    lock.release(holder);
  }
}


/// 这份方案要用到哪些素材（去重，顺序稳定——取素材的进度报出来才好读）
List<int> _neededMaterials(List<UnitReplacement> replacements) {
  final out = <int>{};
  for (final r in replacements) {
    out.addAll(r.wholeCandidateIds);
    for (final ids in r.shotCandidateIds.values) {
      out.addAll(ids);
    }
  }
  return out.toList()..sort();
}
