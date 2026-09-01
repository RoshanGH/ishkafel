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
import '../../core/ai/tag_dimension.dart';
import '../../core/script/script_service_wiring.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/shot_allocation.dart';
import '../ref_shot_tagging.dart';
import '../../core/log/app_log.dart';
import 'analyze_command.dart' show loadCliCredentials;
import '../../core/storage/agent_presence.dart';
import '../agent_stage.dart';
import '../agent_lock_holder.dart';
import '../cli_output.dart';
import '../line_evidence.dart';
import '../search_narrowing.dart';
import '../search_modes.dart';
import '../script_shot_context.dart';
import 'script_apply_command.dart';
import 'script_run_command.dart';
import 'voice_file_command.dart';
import '../script_view.dart';

/// `ishkafel script <子命令> <任务>` —— 脚本成片这条线的只读入口。
///
/// 与替换裂变是同一个任务对象的两个字段（`units` / `script`），所以共用
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

  /// 这次检索用哪些标签（逗号分隔）。**不给就用参考镜打出来的那几个。**
  ///
  /// 人在找镜头面板上做的第一件事往往是「把不合适的标签去掉、把想要的
  /// 加上」——标签是所有检索维度的公共筛选层。此前 Agent 只能被动接受
  /// 参考镜的标签，加不了也减不了，等于少了一个最关键的旋钮。
  /// 给 `--tags ""`（空串）就是这一次不带任何标签约束
  String? searchTags,

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
        '  voice-file <任务> --line N <音频>  用我自己录的配音（时长与台词都以它为准）\n'
        '  show <任务> [--line N]          任务全貌 / 单行详情\n'
        '  shots <任务> --line N           候选镜头与判断依据\n'
        '  subtitles <任务> --line N       断句材料\n'
        '  apply <what> <任务> --file f    回填（shots/subtitles/alloc/bgm/\n'
        '                                  lines/shot-edit/screen-text/\n'
        '                                  baseline/line-voice/mix）\n'
        '  export <任务> [--out 目录]      导出成片\n'
        '  peek <任务> --materials <id,id> 把候选的画面抽到本地，亲眼看看\n'
        '  frames <任务> --line N         这一行能看能听的全给出来（参考镜/已选镜头/配音）\n'
        '  tag-ref <任务> --line N        给参考镜打标（画面描述+标签+首帧图）\n'
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
    case 'voice-file':
      // 用我自己录的配音：时长、逐字时间、甚至台词都以这段录音为准
      return runScriptVoiceFileCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        line: line,
        out: out,
        err: err,
      );
    case 'frames':
      return runScriptFramesCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        line: line,
        out: out,
        err: err,
      );
    case 'tag-ref':
      return runScriptTagRefCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        line: line,
        visual: visual,
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
        visual: visual,
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
        '替换裂变那条线请用 ishkafel task / candidates');
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
      // **没配音就别挑画面。**
      //
      // 这条线的时间根是配音时长（rootMs = voiceover.durationMs）。没有它，
      // 这一行的坑位时长是 0——挑出来的镜头够不够铺、要不要变速，全都无从
      // 判断，等于瞎挑。用户的原话：「我们到底是用什么样的时间去做画面对齐
      // 的？我们用的是口播的时间呀。」
      if (doc.lines[line - 1].type == ScriptLineType.voiced &&
          ShotAllocation.rootMsOf(doc.lines[line - 1]) == null) {
        sink.writeln('第 $line 行还没配音，挑不了画面。\n'
            '**这条线的时间根是配音时长**：这一句念多久，这一行就多长，'
            '画面被切、被变速去凑那个长度。没有它，这一镜该多少秒、'
            '素材够不够铺、要不要变速，全都无从判断。\n'
            '先配音：ishkafel script voice ${task.id}'
            '（音色不对就先 apply baseline 换掉，配完再换要重配一轮）');
        return exitBadUsage;
      }
      // 找镜头是**最该被看见的一步**：人要看着它在给哪一行找、找出了什么。
      // 以前这条命令收了 --visual 却从不上报，于是软件既不拉起、界面也不跟——
      // 人开着别的任务时，看到的是「Agent 说在给第 4 行找镜头」而界面纹丝不动
      final shotsStage = AgentStage(
        mode: AgentStageMode.from(visual: visual),
        dataDir: dataDir,
        taskId: task.id,
      );
      await shotsStage.begin('正在给第 $line 行找镜头',
          focus: AgentFocus(
            module: 'director',
            lineIndex: line - 1,
            panel: AgentPanel.findShots,
          ));
      try {
        // 先给参考镜抽本地首帧：**让 Agent 真的看见要复刻的是什么画面**，
        // 而不是只读一句别人总结的描述。抽过的直接用，不重跑 ffmpeg
        final refVideo = doc.refVideoOf(doc.lines[line - 1]);
        if (refVideo != null && File(refVideo).existsSync()) {
          await shotsStage.show('正在看参考片这一句的画面',
              focus: AgentFocus(
                module: 'director',
                lineIndex: line - 1,
                panel: AgentPanel.findShots,
              ));
        }
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
        // **把过程说出来**：一条命令几秒就跑完，只在开头报一句的话，
        // 人看到的是「跳过去 → 结束」，中间全黑。每一步都握手（界面展示完
        // 才回执），人才跟得上——不是靠加延迟，是靠把在干什么说清楚
        await shotsStage.show(
          switch (mode) {
            SearchMode.tags => '正在按标签找素材',
            SearchMode.content => '正在按画面描述找：$searchKey',
            SearchMode.voiceover => '正在按台词找：$searchKey',
            SearchMode.name => '正在按名字找：$searchKey',
            SearchMode.image => '正在拿这条素材的画面找相似的',
          },
          focus: AgentFocus(
            module: 'director',
            lineIndex: line - 1,
            panel: AgentPanel.findShots,
          ),
        );

        final services = content ?? MiaoaContentService();
        // 标签：**Agent 给了就听它的**（这正是人在面板上做的那一步：
        // 去掉不合适的、加上想要的）；没给才回落到参考镜打出来的那几个
        final wantTags = searchTags == null
            ? (refShots.isEmpty
                ? const <String>[]
                : (refShots.first['tags'] as List).cast<String>())
            : [
                for (final t in searchTags.split(','))
                  if (t.trim().isNotEmpty) t.trim(),
              ];
        final tagIds = await _tagIdsOf(
          tags: wantTags,
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
        // 搜完先说搜到多少——这是人判断「它找的方向对不对」的第一个信号
        await shotsStage.show(
          page.total <= 0
              ? '没找到素材，要换个说法再搜'
              : '找到 ${page.total} 条，正在逐条量时长',
          focus: AgentFocus(
            module: 'director',
            lineIndex: line - 1,
            panel: AgentPanel.findShots,
          ),
        );

        final specs = <int, CandidateSpec>{};
        await Future.wait([
          for (final m in page.items)
            probe
                .probe(
                    materialId: m.id,
                    previewUrl: m.previewUrl,
                    localPath: TaskMedia(dataDir: dataDir, taskId: task.id)
                        .localMaterial(m.id))
                .then((spec) {
              if (spec != null) specs[m.id] = spec;
            }),
        ]);
        await shotsStage.show(
          '量完了：${specs.length}/${page.items.length} 条能用，正在挑',
          focus: AgentFocus(
            module: 'director',
            lineIndex: line - 1,
            panel: AgentPanel.findShots,
          ),
        );

        final narrowing =
            describeNarrowing(projectIds: projectIds, tagIds: tagIds);
        emitJson({
          ...ctx,
          // 这一轮按什么收窄的。没收窄住就明说——搜回来的东西看着都
          // 「像那么回事」，不说的话人拿到成片才发现品牌串了
          'narrowedBy': {
            'projectIds': projectIds,
            'tagCount': tagIds.length,
          },
          'notice': ?narrowing.notice,
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
      } finally {
        // 每条出口都要撤场——漏一条，界面就永远停在「Agent 正在操作」的
        // 只读态上，人得等心跳超时才能自己动手
        shotsStage.end();
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
/// 参考镜的标签 → miaoa 的标签 id。
///
/// [tags] 空时**退回整个标签组的全部标签**，而不是直接放弃约束。
///
/// 真机翻车就在这儿：参考镜没打标 → tags 空 → 旧代码 `return []` →
/// 检索一道约束都没有 → 在全库里捞，混回一堆防晒乳和洗护。
/// 而任务建的时候明明选了「AI自然消毒液原子库」——那个词表本身就是
/// 一道有效的收窄，只是没人用它。
Future<List<int>> _tagIdsOf({
  required List<String> tags,
  required List<dynamic> groups,
  MiaoaTagService? service,
}) async {
  if (groups.isEmpty) return const [];
  try {
    final svc = service ?? MiaoaTagService();
    final all = await svc.listGroups();
    final wanted = {for (final g in groups) g.id as int};
    final ids = <int>[];
    for (final g in all) {
      if (!wanted.contains(g.id)) continue;
      for (final t in await svc.listTags(g.id)) {
        // 打过标就按打出来的那几个；没打标就把这个组的词表整个用上
        if (tags.isEmpty || tags.contains(t.name)) ids.add(t.id);
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

/// `ishkafel script tag-ref <task> --line N` —— 给这一行的参考镜打标。
///
/// `script extract` 只出台词与切点，参考镜的画面描述、标签、首帧图全是空的。
/// 而挑镜头的三条路全依赖它们——验收 Agent 因此只能自己 ffmpeg 抽帧、
/// 肉眼看图、手写关键词，中间多一层有损转译，写偏了就搜回一堆别的品牌。
///
/// **打标花钱**（每镜一次识图），所以按行打、不整片预打；已经打过的跳过。
Future<int> runScriptTagRefCommand({
  required List<String> rest,
  required Directory dataDir,
  int? line,
  bool? visual,
  String? holder,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel script tag-ref <任务 id> --line <行号>');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final script = task.script;
  if (script == null) {
    sink.writeln('「${task.name}」不是脚本成片任务');
    return exitBadUsage;
  }
  if (line == null) {
    sink.writeln('要指定行号：--line <行号>（从 1 开始）。'
        '打标每镜一次识图、是花钱的一步，所以按行打');
    return exitBadUsage;
  }
  var doc = script;
  final index = line - 1;
  if (index < 0 || index >= doc.lines.length) {
    sink.writeln('没有第 $line 行（这个脚本共 ${doc.lines.length} 行）');
    return exitNotFound;
  }
  final target = doc.lines[index];
  final ref = target.reference;
  final video = doc.refVideoOf(target);
  // 三种情况分开说。混成一句「手写的脚本没有参考镜」害过人：参考片明明在，
  // 只是文件当时读不到，而那句话把人往「你这是手写脚本」上引，
  // 于是他去重装、删任务、重建任务，全白干
  if (ref == null || video == null) {
    sink.writeln('第 $line 行没有参考片可打标。'
        '手写的脚本没有参考镜——用 script shots --by content --keyword "画面描述" 直接搜');
    return exitBadUsage;
  }
  if (!File(video).existsSync()) {
    sink.writeln('参考片读不到：$video\n'
        '**这一行是有参考镜的**，只是文件此刻打不开。常见两种：\n'
        '· 文件被移动或删掉了——把它放回原处，或重新 script extract 一次\n'
        '· 它在「文稿」「桌面」「下载」这类目录下，而命令行工具还没拿到访问'
        '授权——系统会弹一次「ishkafel 想访问…文件夹」，点允许之后重跑这条');
    return exitFailed;
  }

  // 走 CLI 那份凭据加载：它会去 <dataDir>/credentials 找，
  // 而不是只看编译期注入的（命令行跑的时候没有那一份）
  final tagger = buildRefShotTagger(loadCliCredentials(dataDir));
  if (tagger == null) {
    sink.writeln('尚未配置 AI 服务（视觉理解），打不了标。'
        '让用户在 app 的设置里补上凭据');
    return exitEnv;
  }
  // 视觉镜头层用**视觉镜头标签组**的词表（与单元层的话术标签不同）
  final groups = task.shotTagGroups.isNotEmpty
      ? task.shotTagGroups
      : task.unitTagGroups;
  final vocab = <TagDimension>[];
  try {
    final all = await MiaoaTagService().listGroups();
    for (final g in groups) {
      final hit = all.where((x) => x.id == g.id).firstOrNull;
      if (hit != null && hit.tags.isNotEmpty) {
        vocab.add(TagDimension(name: hit.name, vocabulary: hit.tags));
      }
    }
  } catch (e) {
    // 拉不到词表也要打——画面描述不依赖词表，而它正是检索键
    AppLog.warn('拉标签词表失败（只出画面描述）：$e');
  }

  // **打标是全流程里最慢最贵的一段**：25 句、47 个参考镜、十几分钟、
  // 每一镜一次识图。此前它一声不吭——人对着任务列表干等一刻钟，
  // 看不出它在干什么、到哪一步了、是不是卡死了（验收时人在旁边看着，
  // 那是整条流程里唯一一段纯黑屏）。
  //
  // 进度要带**分母**，而且是**整片的分母**：人要的不是「正在打标」，
  // 是「看着数字在往前走」。tag-ref 是按行调用的，所以这里从整份脚本
  // 算总数与已完成数，跨调用也接得上
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder ?? agentLockHolder,
  );
  final totalShots = _refShotCount(doc);
  var taggedSoFar = _taggedRefShotCount(doc);
  await stage.begin(
      '正在看参考片的画面（第 $line 句，全片 $taggedSoFar/$totalShots 镜）',
      focus: AgentFocus(
          module: 'director', lineIndex: index, panel: AgentPanel.findShots));

  final done = <Map<String, dynamic>>[];
  for (var k = 0; k < ref.segments.length; k++) {
    if ((ref.metaAt(ref.segments[k].$1)?.description ?? '').isNotEmpty) {
      continue; // 打过的跳过：这一步花钱
    }
    await stage.show(
        '正在看第 $line 句的第 ${k + 1} 个参考镜'
        '（全片 ${taggedSoFar + 1}/$totalShots 镜）',
        focus: AgentFocus(
            module: 'director',
            lineIndex: index,
            shotIndex: k,
            panel: AgentPanel.findShots));
    final meta = await tagRefShot(
      line: doc.lines[index],
      videoPath: video,
      segIndex: k,
      workDir: Directory(p.join(dataDir.path, 'script_refs', task.id)),
      tagger: tagger,
      vocabulary: vocab,
      constraint: task.shotTagPrompt.isEmpty ? null : task.shotTagPrompt,
    );
    if (meta == null) continue;
    doc = doc.setReferenceById(
        doc.lines[index].id, doc.lines[index].reference!.withShotMeta(meta));
    taggedSoFar++;
    // **每打完一镜就落盘**，不等整行做完。
    //
    // 界面是靠读盘跟上进度的：攒到整行才写一次，人看到的就是「播报都到
    // 第 7 个参考镜了，画面上还一个都没出现」，然后忽然整行刷出来。
    // 用户反复说的就是这件事——**一步一步长出来，不是全做完再刷一下**。
    await repository.save(task.copyWith(script: doc, updatedAt: DateTime.now()));
    done.add({
      'shotIndex': k,
      'description': meta.description,
      'tags': meta.tags,
      if (meta.framePath != null) 'framePath': meta.framePath,
    });
  }
  await repository.save(task.copyWith(script: doc, updatedAt: DateTime.now()));
  stage.end();
  emitJson({
    'ok': true,
    'lineIndex': index,
    'tagged': done.length,
    'shots': done,
    'next': '现在可以挑镜头了：ishkafel script shots ${task.id} --line $line',
  }, out: out);
  return 0;
}

/// `ishkafel script frames <task> --line N` ——
/// 把这一行**人能看到、听到的每一样东西**的本地路径给出来。
///
/// 设计原则（用户的原话）：「你想让 Agent 完全还原一个优秀的人的操作，
/// 那你首先得让它拥有所有这个人能够拥有的信息。」
///
/// 典型场景：人说「第 3 行你找的这个分镜不对」。Agent 得能**看见**——
/// 参考镜长什么样（要复刻的目标）、自己选的那一镜长什么样（现在的结果），
/// 才谈得上跟人确认「你是嫌画面太暗、还是这个动作不对」。看不见就只能
/// 瞎猜着换关键词重搜，而人要的可能根本不是那个方向。
///
/// **已选镜头抽的是成片里真正出现的那一帧**（取段之后），不是素材开头——
/// 给错了帧，Agent 看到的不是成片里的东西，跟人讨论时对不上。
Future<int> runScriptFramesCommand({
  required List<String> rest,
  required Directory dataDir,
  int? line,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel script frames <任务 id> --line <行号>');
    return exitBadUsage;
  }
  final task = await resolveTaskRef(FileTaskRepository(dataDir), rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final doc = task.script;
  if (doc == null) {
    sink.writeln('「${task.name}」不是脚本成片任务');
    return exitBadUsage;
  }
  if (line == null || line < 1 || line > doc.lines.length) {
    sink.writeln('要指定行号：--line <1~${doc.lines.length}>');
    return exitBadUsage;
  }
  final target = doc.lines[line - 1];
  final media = TaskMedia(dataDir: dataDir, taskId: task.id);

  Future<String?> frameOf(String video, int atMs) => ensureFrame(
        dataDir: dataDir,
        videoPath: video,
        atMs: atMs,
        extract: (v, o, ms) async {
          Directory(p.dirname(o)).createSync(recursive: true);
          await ThumbnailService(run: const ResolvingProcessRunner().call)
              .extractCover(videoPath: v, outPath: o, atSeconds: ms / 1000);
          return true;
        },
      );

  // 一、参考镜：要复刻的目标长什么样。**不依赖打标**——抽帧不花钱，
  // 打标才花钱，没道理因为没打标就不让人看见画面
  final refFrames = <Map<String, dynamic>>[];
  final refVideo = doc.refVideoOf(target);
  if (refVideo != null && File(refVideo).existsSync()) {
    final segs = target.reference!.segments;
    for (var k = 0; k < segs.length; k++) {
      final (a, b) = segs[k];
      final meta = target.reference!.metaAt(a);
      final f = await frameOf(refVideo, a + (b - a) ~/ 2);
      refFrames.add({
        'shotIndex': k,
        'startMs': a,
        'endMs': b,
        'framePath': ?f,
        if ((meta?.description ?? '').isNotEmpty) 'description': meta!.description,
        if ((meta?.tags ?? const []).isNotEmpty) 'tags': meta!.tags,
        'asr': target.reference!.segmentText(k, ''),
      });
    }
  }

  // 二、已选镜头：现在的结果长什么样
  final picked = <Map<String, dynamic>>[];
  for (var j = 0; j < target.shots.length; j++) {
    final s = target.shots[j];
    final local = s.localSource ?? media.localMaterial(s.materialId);
    String? frame;
    if (local != null && File(local).existsSync()) {
      frame = await frameOf(local, evidenceFrameAtMs(s));
    }
    picked.add({
      'shotIndex': j,
      'materialId': s.materialId,
      'name': s.name,
      if (s.allocMs != null) 'allocMs': s.allocMs,
      'trimStartMs': s.trimStartMs,
      'speed': s.speed,
      // 画面自查：烧没烧字、露的是谁家产品。**两样都只有看图才知道**，
      // 而且都会毁掉整片——这条线自己要给台词烧一行字幕，素材再自带一层
      // 就是两层字叠在一起。framesSeen 为 null = 没看成，不是「没问题」
      if (s.burnedText != null) 'burnedText': s.burnedText,
      if (s.productBrand != null) 'productBrand': s.productBrand,
      if (s.framesSeen != null) 'framesSeen': s.framesSeen,
      'videoPath': ?local,
      'framePath': ?frame,
      if (local == null)
        'note': '这条素材还没下到本地——script peek --materials ${s.materialId} 会下',
    });
  }

  emitJson({
    'taskId': task.id,
    'lineIndex': line - 1,
    'text': target.text,
    'reference': refFrames,
    'picked': picked,
    // 三、配音：人能听，Agent 也得知道文件在哪
    if (target.voiceover?.audioPath case final a?)
      if (File(a).existsSync()) 'voiceAudioPath': a,
    'next': '打开 framePath 看图。参考镜是**要复刻的目标**、picked 是'
        '**现在的结果**——人说「这一镜不对」时，先看这两张图差在哪，'
        '再问清楚他要的是什么方向，别直接换个词重搜',
  }, out: out);
  return 0;
}


/// 整份脚本一共有多少个参考镜、其中打过标的有几个。
///
/// 进度要有**整片的分母**——按行调用时只报「这一行第 2/3 镜」，人还是
/// 不知道整件事走到哪了。要的是看着一个数字一路涨到头
int _refShotCount(ScriptDoc doc) {
  var n = 0;
  for (final line in doc.lines) {
    n += line.reference?.segments.length ?? 0;
  }
  return n;
}

int _taggedRefShotCount(ScriptDoc doc) {
  var n = 0;
  for (final line in doc.lines) {
    final ref = line.reference;
    if (ref == null) continue;
    for (final (start, _) in ref.segments) {
      if ((ref.metaAt(start)?.description ?? '').isNotEmpty) n++;
    }
  }
  return n;
}
