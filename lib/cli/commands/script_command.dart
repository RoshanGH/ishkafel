import 'dart:io';

import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../agent_frames.dart';
import 'package:path/path.dart' as p;
import '../../core/ffmpeg/process_runner.dart';
import '../../core/miaoa/material_downloader.dart';
import '../../core/storage/task_media.dart';
import '../../core/miaoa/candidate_probe.dart';
import '../../core/audio/bgm_library.dart';
import '../cli_output.dart';
import '../search_modes.dart';
import '../script_shot_context.dart';
import 'script_apply_command.dart';
import 'script_run_command.dart';
import '../script_view.dart';

/// `ishkafel script <子命令> <任务>` —— 脚本成片这条线的只读入口。
///
/// 与成片翻新是同一个任务对象的两个字段（`units` / `script`），所以共用
/// 仓库与输出层，只在这里开一层新的命名空间。
///
/// 子命令：
/// - `show <task> [--line <i>]`：任务全貌 / 单行详情
/// - `shots <task> --line <i>`：这一行的候选镜头与判断依据
/// - `subtitles <task> --line <i>`：这一行的断句材料
Future<int> runScriptCommand({
  required List<String> rest,
  required Directory dataDir,
  int? line,

  /// `apply` 用：结果文件路径
  String? file,

  /// `voice` 用：指定音色
  String? voiceId,

  /// 没有参考镜时，自己给一句**画面描述**去搜（不是台词）
  String? keyword,

  /// script peek 用：要看哪几条素材；
  /// script shots --by image 用：拿哪条素材的画面去找相似
  String? materials,

  /// 检索方式（tags / content / image / voiceover / name）
  String? by,

  /// `export` 用：输出目录
  String? outputDir,

  /// 可视模式：把软件拉起来，一步一步演给人看
  bool? visual,

  /// 注入点：测试用假实现，真实环境走 miaoa CLI
  MiaoaContentService? content,
  MiaoaTagService? tags,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel script <子命令> …\n'
        '  new <名字>                      建一个脚本任务\n'
        '  extract <任务> <参考视频>        识别台词，生成脚本行\n'
        '  voice <任务> [--line N]         生成配音\n'
        '  show <任务> [--line N]          任务全貌 / 单行详情\n'
        '  shots <任务> --line N           候选镜头与判断依据\n'
        '  subtitles <任务> --line N       断句材料\n'
        '  apply <what> <任务> --file f    回填（shots/subtitles/alloc/bgm/\n'
        '                                  lines/shot-edit/screen-text/\n'
        '                                  baseline/line-voice/mix）\n'
        '  export <任务> [--out 目录]      导出成片\n'
        '  peek <任务> --materials <id,id> 把候选的画面抽到本地，亲眼看看\n'
        '  bgm-candidates <任务> [--keyword 轻快]  有哪些配乐可选\n'
        '  jianying <任务>                 写成剪映草稿，去剪映里精修');
    return exitBadUsage;
  }
  if (rest.length < 2 &&
      !['new'].contains(rest.first)) {
    sink.writeln('要指定任务：ishkafel script ${rest.first} <任务 id>');
    return exitBadUsage;
  }
  final sub = rest[0];
  // 执行类：建任务、提取、配音、导出（这几条不需要先解析任务）
  switch (sub) {
    case 'new':
      return runScriptNewCommand(
          rest: rest.sublist(1), dataDir: dataDir, out: out, err: err);
    case 'extract':
      return runScriptExtractCommand(
          rest: rest.sublist(1), dataDir: dataDir, out: out, err: err);
    case 'voice':
      return runScriptVoiceCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        line: line,
        voiceId: voiceId,
        out: out,
        err: err,
      );
    case 'bgm-candidates':
      return runScriptBgmCandidatesCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        keyword: keyword,
        out: out,
        err: err,
      );
    case 'peek':
      return runScriptPeekCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        materials: materials,
        out: out,
        err: err,
      );
    case 'jianying':
      return runScriptJianyingCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        visual: visual,
        out: out,
        err: err,
      );
    case 'export':
      return runScriptExportCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        outputDir: outputDir,
        out: out,
        err: err,
      );
  }
  // apply 多一层：script apply <what> <task>
  if (sub == 'apply') {
    return runScriptApplyCommand(
      rest: rest.sublist(1),
      dataDir: dataDir,
      file: file,
      visual: visual,
      out: out,
      err: err,
    );
  }
  final id = rest[1];
  final task = await resolveTaskRef(FileTaskRepository(dataDir), id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  final doc = task.script;
  if (doc == null) {
    sink.writeln('「${task.name}」不是脚本成片任务——'
        '成片翻新那条线请用 ishkafel task / candidates');
    return exitBadUsage;
  }

  switch (sub) {
    case 'apply':
      // script apply <what> <task> …：把 apply 之后的参数原样递过去
      return runScriptApplyCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        file: file,
        visual: visual,
        out: out,
        err: err,
      );
    case 'show':
      try {
        // --line 给的是**人看的行号**（从 1 起），内部一律 0 起
        emitJson(
            line == null
                ? scriptTaskJson(task)
                : scriptLineJson(doc, line - 1),
            out: out);
        return 0;
      } on ArgumentError catch (e) {
        sink.writeln('${e.message}');
        return exitBadUsage;
      }
    case 'shots':
      if (line == null) {
        sink.writeln('要指定行号：ishkafel script shots <任务> --line <行号>');
        return exitBadUsage;
      }
      try {
        // 先给参考镜抽本地首帧：**让 Agent 真的看见要复刻的是什么画面**，
        // 而不是只读一句别人总结的描述。抽过的直接用，不重跑 ffmpeg
        final refVideo = doc.lines[line - 1].reference?.videoPath;
        final refSegs =
            doc.lines[line - 1].reference?.segments ?? const <(int, int)>[];
        final frames = <int, String>{};
        if (refVideo != null && File(refVideo).existsSync()) {
          for (var k = 0; k < refSegs.length; k++) {
            final (a, b) = refSegs[k];
            // 取中点：两端常踩在转场上，抽出来是糊的
            final at = a + (b - a) ~/ 2;
            final got = await ensureFrame(
              dataDir: dataDir,
              videoPath: refVideo,
              atMs: at,
              extract: (video, out, ms) async {
                Directory(p.dirname(out)).createSync(recursive: true);
                await ThumbnailService(run: const ResolvingProcessRunner().call)
                    .extractCover(
                  videoPath: video,
                  outPath: out,
                  atSeconds: ms / 1000,
                );
                return true;
              },
            );
            if (got != null) frames[k] = got;
          }
        }
        final ctx = scriptShotContext(doc, line - 1,
            refFrameOf: (k) => frames[k]);
        // 候选走**与界面完全同一条路**：参考镜打过标就按它的画面描述搜。
        // 绝不退回「拿台词搜画面描述」——那个错配 0.1.45 刚砍掉，
        // 台词是一句话、画面描述是一幅画，不在一个维度上
        final refShots = ctx['reference'] as List;
        final description = refShots.isEmpty
            ? ''
            : '${refShots.first['description']}'.trim();
        // 没有参考镜时**允许自己给一句画面描述**（--keyword）。
        //
        // 原来这里直接返回空候选，而 hint 却写着「只能按台词与标签找」
        // ——那条路根本没有对应的参数，`--keyword` 传了会被默默吃掉。
        // 验收 Agent 撞上了：hint 指了一条不存在的路，它试了参数、
        // 不报错也不生效，只能干等着。
        //
        // 要点：**描述的是画面**（「一只手在厨房台面上举着喷雾瓶」），
        // 不是台词。拿台词去搜画面描述是 0.1.45 砍掉的错配——
        // 台词是一句话、画面是一幅画，不在一个维度上
        // 检索方式：**与界面上人能用的完全一致**（五种）。
        // 不给 --by 时按参考镜的画面描述搜——那是复刻的默认路子
        final mode = SearchMode.parse(by) ??
            (by == null ? SearchMode.content : null);
        if (mode == null) {
          sink.writeln('认不出的检索方式「$by」。可用：\n'
              '${[
            for (final m in SearchMode.values)
              '  ${m.wire.padRight(10)} ${m.label}——${m.whenToUse}'
          ].join('\n')}');
          return exitBadUsage;
        }
        final searchKey =
            (keyword ?? '').trim().isNotEmpty ? keyword!.trim() : description;
        if (mode.needsKeyword && searchKey.isEmpty) {
          sink.writeln('${mode.label}要给一个关键词：--keyword "…"'
              '${mode == SearchMode.content ? '（描述的是画面，不是台词）' : ''}');
          return exitBadUsage;
        }
        if (mode.needsMaterial && (materials ?? '').trim().isEmpty) {
          sink.writeln('以图搜图要指定拿哪条素材的画面去找：'
              '--materials <素材 id>（从 candidates 里挑一条像的）');
          return exitBadUsage;
        }
        if (!mode.needsKeyword && !mode.needsMaterial && searchKey.isEmpty) {
          // 按标签搜：标签从参考镜带过来，没有参考镜就没标签可用
          emitJson({...ctx, 'candidates': const []}, out: out);
          return 0;
        }
        final services = content ?? MiaoaContentService();
        final tagIds = await _tagIdsOf(
          tags: refShots.isEmpty
              ? const <String>[]
              : (refShots.first['tags'] as List).cast<String>(),
          groups: [...task.shotTagGroups, ...task.unitTagGroups],
          service: tags,
        );
        final projectIds = [if (task.project != null) task.project!.id];
        final page = switch (mode) {
          SearchMode.tags => await services.searchByTags(
              tagIds: tagIds, projectIds: projectIds, pageSize: 20),
          SearchMode.content => await services.searchByDescription(
              keyword: searchKey,
              tagIds: tagIds,
              projectIds: projectIds,
              pageSize: 20),
          SearchMode.voiceover => await services.searchByVoiceover(
              keyword: searchKey,
              tagIds: tagIds,
              projectIds: projectIds,
              pageSize: 20),
          SearchMode.name => await services.searchByName(
              keyword: searchKey,
              tagIds: tagIds,
              projectIds: projectIds,
              pageSize: 20),
          // 以图搜图：拿指定素材的 fileKey 去找相似。**复刻最该用这个**
          SearchMode.image => await _searchLikeImage(
              services: services,
              materials: materials!,
              tagIds: tagIds,
              projectIds: projectIds,
              sink: sink),
        };
        // **必须带上时长**：提交时校验要拿它算「这一镜够不够铺」。
        //
        // 不给的话照手册原样带回来的候选一律算成 0 秒，整批被拒——
        // 真机上验收 Agent 21 行全废，而它完全是照手册做的。
        // 界面那边一直是拿 previewUrl 现探（见 CandidateProbe），
        // 只是 CLI 这条路漏了这一步。miaoa 的搜索结果本身不带时长
        // ResolvingProcessRunner 自己会把 ffprobe 解析到真实路径
        // （GUI 进程的 PATH 不含 Homebrew 目录，这一层早就处理过）
        final probe = CandidateProbe(run: const ResolvingProcessRunner().call);
        final specs = <int, CandidateSpec>{};
        await Future.wait([
          for (final m in page.items)
            probe
                .probe(materialId: m.id, previewUrl: m.previewUrl)
                .then((spec) {
              if (spec != null) specs[m.id] = spec;
            }),
        ]);
        emitJson({
          ...ctx,
          'candidates': [
            for (final m in page.items)
              {
                'materialId': m.id,
                'name': m.name,
                'sceneDescription': m.sceneDescription,
                'voiceover': m.voiceover,
                'tags': m.tags,
                // 这条素材有多长、还能出多少成片时长。提交时原样带回来
                if (specs[m.id] case final spec?) ...{
                  'durationMs': spec.durationMs,
                  'availableMs': spec.durationMs,
                },
                if (m.thumbnailUrl != null) 'thumbnailUrl': m.thumbnailUrl,
                if (m.fileKey != null) 'fileKey': m.fileKey,
              },
          ],
          // 想**亲眼看**某几条候选长什么样，用这条把它们的画面抽到本地：
          // 一条几十兆，所以不在这里替你全下——你先按描述和标签筛一轮，
          // 拿不准的那几条再看图
          'peek': 'ishkafel script peek <任务> --materials <id,id>',
        }, out: out);
        return 0;
      } on ArgumentError catch (e) {
        sink.writeln('${e.message}');
        return exitBadUsage;
      }
    case 'subtitles':
      if (line == null) {
        sink.writeln('要指定行号：ishkafel script subtitles <任务> --line <行号>');
        return exitBadUsage;
      }
      try {
        emitJson(scriptSubtitleMaterial(doc, line - 1), out: out);
        return 0;
      } on ArgumentError catch (e) {
        sink.writeln('${e.message}');
        return exitBadUsage;
      }
    default:
      sink.writeln('不认识的子命令：$sub'
          '（可用：new / extract / voice / export / show / shots / subtitles / apply）');
      return exitBadUsage;
  }
}

/// 参考镜的画面标签 → 标签 id（检索约束）。拉不到就不带约束，不挡路
Future<List<int>> _tagIdsOf({
  required List<String> tags,
  required List<dynamic> groups,
  MiaoaTagService? service,
}) async {
  if (tags.isEmpty) return const [];
  try {
    final svc = service ?? MiaoaTagService();
    final all = await svc.listGroups();
    final wanted = {for (final g in groups) g.id as int};
    final ids = <int>[];
    for (final g in all) {
      if (!wanted.contains(g.id)) continue;
      for (final t in await svc.listTags(g.id)) {
        if (tags.contains(t.name)) ids.add(t.id);
      }
    }
    return ids;
  } catch (_) {
    return const [];
  }
}

/// `ishkafel script peek <task> --materials <id,id>` ——
/// 把这几条候选素材的画面抽到本地，返回图片路径。
///
/// 用户要的能力：「**就像人看到这个东西一样，Agent 也要看到这个东西**，
/// 然后拿这个东西去搜索出对应的分镜。」
///
/// 光看 `sceneDescription` 是看别人（打标 AI）总结过的二手信息，
/// 判断「这一镜像不像参考片那一镜」得看图。
///
/// **按需下载**：一条素材几十兆，不能在列候选时就全下。先按描述和标签
/// 筛一轮，拿不准的那几条再 peek。
Future<int> runScriptPeekCommand({
  required List<String> rest,
  required Directory dataDir,
  String? materials,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel script peek <任务 id> --materials <素材 id，逗号分隔>');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final ids = <int>[
    for (final piece in (materials ?? '').split(','))
      ?int.tryParse(piece.trim()),
  ];
  if (ids.isEmpty) {
    sink.writeln('没说要看哪几条：--materials 12345,12346');
    return exitBadUsage;
  }

  final media = TaskMedia(dataDir: dataDir, taskId: task.id);
  final downloader = MaterialDownloader(
    content: MiaoaContentService(),
    cacheDir: media.materialsDir,
  );
  final frames = <Map<String, dynamic>>[];
  final failed = <String>[];
  for (final id in ids) {
    try {
      final local = media.localMaterial(id) ?? await downloader.fetch(id);
      final frame = await ensureFrame(
        dataDir: dataDir,
        videoPath: local,
        atMs: 1000, // 第 1 秒：开头常有转场/黑帧
        extract: (video, outPath, ms) async {
          Directory(p.dirname(outPath)).createSync(recursive: true);
          await ThumbnailService(run: const ResolvingProcessRunner().call)
              .extractCover(
                  videoPath: video, outPath: outPath, atSeconds: ms / 1000);
          return true;
        },
      );
      if (frame == null) {
        failed.add('$id（抽帧失败）');
        continue;
      }
      frames.add({'materialId': id, 'framePath': frame, 'videoPath': local});
    } catch (e) {
      // 一条失败不挡其余：Agent 拿到能看的那几条照样能往下判断
      failed.add('$id（$e）');
    }
  }
  emitJson({
    'frames': frames,
    if (failed.isNotEmpty) 'failed': failed,
    'next': '直接打开 framePath 看图，像人一样判断这一镜像不像',
  }, out: out);
  return frames.isEmpty ? exitFailed : 0;
}


/// 以图搜图：拿某条素材的画面去找相似的。
///
/// 界面上人是「在候选里看到一条像的 → 点『找相似』」，这里是同一件事，
/// 只是把那条素材的 id 用参数给出来
Future<CandidatePage> _searchLikeImage({
  required MiaoaContentService services,
  required String materials,
  required List<int> tagIds,
  required List<int> projectIds,
  required StringSink sink,
}) async {
  final id = int.tryParse(materials.split(',').first.trim());
  if (id == null) {
    throw ArgumentError('--materials 要给素材 id，给的是「$materials」');
  }
  final m = await services.fetchById(id);
  final key = m?.fileKey;
  if (key == null || key.isEmpty) {
    throw ArgumentError('素材 $id 没有可用来搜相似的画面（缺 fileKey）');
  }
  return services.searchByImage(
      fileKey: key, tagIds: tagIds, projectIds: projectIds, pageSize: 20);
}

/// `ishkafel script bgm-candidates <task> [--keyword 轻快]` ——
/// 有哪些配乐可选。
///
/// 之前这条命令**不存在**：手册的提交样例里有个 `offered`（候选曲子），
/// 但全文没有一句说它从哪来。`script shots` 搜的是视频素材、`script show`
/// 里 `bgm` 是空的——验收 Agent 找遍了也拿不到候选，配乐这一步整个断掉，
/// 成片只能没有 BGM。
Future<int> runScriptBgmCandidatesCommand({
  required List<String> rest,
  required Directory dataDir,
  String? keyword,
  BgmLibrary? library,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel script bgm-candidates <任务 id> [--keyword 轻快]');
    return exitBadUsage;
  }
  final task = await resolveTaskRef(FileTaskRepository(dataDir), rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  try {
    final page = await (library ?? BgmLibrary()).search(
      keyword: keyword,
      projectIds: [if (task.project != null) task.project!.id],
      pageSize: 30,
    );
    emitJson({
      'taskId': task.id,
      if (page.widenedFromProject)
        'notice': '这个项目下没搜到，已经放开到全库——曲子可能不贴这条片子的调性',
      'candidates': [
        for (final m in page.items)
          {
            'materialId': m.id,
            'name': m.name,
            'durationMs': m.durationMs,
            if (m.tags.isNotEmpty) 'tags': m.tags,
          },
      ],
      'next': '把这里的 materialId 填进 apply bgm 的 offered 与各段；'
          '某几行不铺配乐的话，那一段把 materialId 整个省掉',
    }, out: out);
    return 0;
  } on MiaoaException catch (e) {
    sink.writeln(e.message);
    return exitEnv;
  }
}
