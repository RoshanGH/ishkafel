import 'dart:io';

import '../../core/miaoa/candidate_probe.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/miaoa/tag_id_resolver.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../../features/picking/tag_hit_probe.dart';
import '../../features/picking/tag_query_narrowing.dart';
import '../../features/picking/project_exclusion.dart';
import '../../features/picking/tag_result_usability.dart';
import '../../core/storage/agent_presence.dart';
import '../agent_stage.dart';
import '../candidate_context.dart';
import '../cli_output.dart';

/// `ishkafel candidates [task] --unit [i] --shot/--keyword 等（详见用法行）
///
/// 返回候选素材 + **上下文**。候选带 miaoa 的图片 URL、不落地——按 spec
/// 的决定，看不看图、怎么去重、选哪几个，全是调用方的判断。
///
/// 检索两种方式（与 GUI 同源）：
/// - 缺省按这一层的标签检索，并做与 GUI 相同的**收窄**（剔掉 0 条的和
///   「实拍」这类命中全库九成、等于没筛的标签）；
/// - `--keyword` 走画面描述语义搜——标签打不上、或按标签搜不出东西时的
///   第二条路（GUI 也是这么降级的）。
///
/// **候选不带时长**：`CandidateMaterial` 没有这个字段，miaoa 的检索结果不含
/// 时长；GUI 上那个「+1.5s」是另外逐条探测出来的（每条一次网络 + ffprobe）。
/// 在候选列表里同步做会让这条命令慢到不可用。
Future<int> runCandidatesCommand({
  required List<String> rest,
  required Directory dataDir,
  required int? unitIndex,
  required int? shotIndex,
  String? keyword,
  String? excludeProjects,

  /// 探一下每条候选多长、选它会变速多少。
  /// 默认不探：一页 50 条各跑一次 ffprobe，慢到人会以为卡死了
  bool probeDurations = false,
  CandidateProbe? probe,

  /// 可视模式：把软件拉起来，选中这一镜、右栏切到「替换素材」，
  /// 让人看得见 Agent 在挑哪一镜
  bool? visual,
  int page = 1,
  String tagMode = 'or',
  int pageSize = 50,
  MiaoaContentService? contentService,
  MiaoaTagService? tagService,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty || unitIndex == null) {
    sink.writeln('用法：ishkafel candidates <任务 id> --unit <单元下标> '
        '[--shot <镜头下标>] [--keyword 词] [--page N] [--tag-mode and|or]');
    return exitBadUsage;
  }
  if (tagMode != 'and' && tagMode != 'or') {
    sink.writeln('--tag-mode 只能是 and 或 or，收到的是「$tagMode」');
    return exitBadUsage;
  }
  if (page < 1) {
    sink.writeln('--page 从 1 开始');
    return exitBadUsage;
  }

  final task = await resolveTaskRef(FileTaskRepository(dataDir), rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final units = task.units;
  if (units == null) {
    sink.writeln('这个任务还没分析完，没有单元可挑');
    return exitNotFound;
  }
  if (unitIndex < 0 || unitIndex >= units.length) {
    sink.writeln('没有第 $unitIndex 个单元（共 ${units.length} 个）');
    return exitNotFound;
  }
  final shots = units[unitIndex].shots;
  if (shotIndex != null && (shotIndex < 0 || shotIndex >= shots.length)) {
    sink.writeln('U${unitIndex + 1} 没有第 $shotIndex 个镜头（共 ${shots.length} 个）');
    return exitNotFound;
  }

  final excluded = <int>{
    for (final raw in (excludeProjects ?? '').split(','))
      if (int.tryParse(raw.trim()) case final id?) id,
  };
  if ((excludeProjects ?? '').trim().isNotEmpty && excluded.isEmpty) {
    sink.writeln('--exclude-projects 认不出来：'
        '要的是逗号分隔的项目 id（比如 --exclude-projects 107,120）。'
        '项目 id 在 `ishkafel task <任务>` 的 project 字段里');
    return exitBadUsage;
  }

  // 挑素材是**最该被看见的一步**——人要看着它挑哪一镜、挑出了什么。
  // 只有这一步和提交方案是真正在做决策的地方
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
  );
  await stage.begin(
    shotIndex == null
        ? '正在给 U${unitIndex + 1} 找素材'
        : '正在给 U${unitIndex + 1}S${shotIndex + 1} 找素材',
    focus: _focus(unitIndex, shotIndex),
  );

  final service = contentService ?? MiaoaContentService();
  final projectIds = [?task.project?.id];

  final ExcludedCandidatePage filtered;
  Map<String, Object?>? narrowNote;
  Map<String, Object?>? fallbackNote;
  int? libraryTotal;
  if (keyword != null && keyword.trim().isNotEmpty) {
    // 画面描述语义搜：标签打不上（话术标签几乎没人打）时的第二条路
    await stage.show('正在按画面描述找：${keyword.trim()}',
        focus: _focus(unitIndex, shotIndex));
    filtered = await searchExcluding(
      fetch: (p) => service.searchByDescription(
        keyword: keyword.trim(),
        projectIds: projectIds,
        page: p,
        pageSize: pageSize,
      ),
      exclude: excluded,
      want: pageSize,
      firstPage: page,
    );
  } else {
    // 打标产出的是标签**名**（受控词表就是名字），而 miaoa 的检索只收标签
    // **id**，中间必须有一次映射，映射表来自任务选定的标签组
    final resolver = TagIdResolver(tagService ?? MiaoaTagService());
    await resolver.loadAll({
      for (final g in task.unitTagGroups) g.id,
      for (final g in task.shotTagGroups) g.id,
    });
    if (resolver.loadFailure case final failure?) {
      sink.writeln(failure);
      return exitEnv;
    }

    final tagNames =
        shotIndex == null ? units[unitIndex].tags : shots[shotIndex].tags;
    final tagIds = resolver.idsOf(tagNames);
    if (tagIds.isEmpty) {
      sink.writeln(tagNames.isEmpty
          ? '这一层还没有标签。用 --keyword <画面描述> 按语义检索，'
              '或先确认任务选了标签组、且已完成打标'
          : '这些标签在素材库里找不到对应项（可能已被改名或删除）：'
              '${tagNames.join('、')}。可改用 --keyword <画面描述> 检索');
      return exitNotFound;
    }

    // 与 GUI 相同的收窄：剔掉 0 条的和「实拍」这类命中全库九成、等于
    // 没筛的标签——不收窄的话半个素材库都会被捞回来
    var effectiveIds = tagIds;
    try {
      final probe = TagHitProbe(service);
      final hits = await probe.probe(tags: [
        for (final name in tagNames)
          if (resolver.idsOf([name]).firstOrNull case final id?)
            (name: name, id: id),
      ], projectIds: projectIds);
      libraryTotal = await probe.libraryTotal(projectIds: projectIds);
      final narrowed =
          narrowTagQuery(hits: hits, libraryTotal: libraryTotal);
      if (narrowed.tagIds.isNotEmpty) {
        effectiveIds = narrowed.tagIds;
        final dropped = [...narrowed.droppedEmpty, ...narrowed.droppedBroad];
        if (dropped.isNotEmpty) {
          narrowNote = {
            'droppedTags': dropped,
            'note': '这些标签命中 0 条或宽到等于没筛，已从检索键中剔除',
          };
        }
      }
    } catch (e) {
      // 收窄失败不拦检索：按原样搜，宽也好过搜不出
      sink.writeln('标签收窄失败，按原样检索：$e');
    }

    await stage.show('正在按这一镜的标签找素材',
        focus: _focus(unitIndex, shotIndex));
    final byTags = await service.searchByTags(
      tagIds: effectiveIds,
      mode: tagMode,
      projectIds: projectIds,
      page: page,
      pageSize: pageSize,
    );

    // 收窄之后还是没筛住的话，这 50 条就是「几万条里最新的 50 条」，
    // 跟像不像无关（真机：total 11265，要「女孩在书桌前诉说」，
    // 首条给「户外街道女士与男孩交谈」）。这时候自动改走画面描述语义搜，
    // 并把换了这件事说出来——不说就是静默换了一套结果
    final usable = tagResultIsUsable(
      total: byTags.total,
      returned: byTags.items.length,
      pageSize: pageSize,
    );
    final semantic = (shotIndex == null
            ? units[unitIndex].transcript
            : shots[shotIndex].description) ??
        '';
    if (!usable && semantic.trim().isNotEmpty) {
      await stage.show(
          '标签命中 ${byTags.total} 条太宽，改用画面描述再找一轮',
          focus: _focus(unitIndex, shotIndex));
      filtered = await searchExcluding(
        fetch: (p) => service.searchByDescription(
          keyword: semantic.trim(),
          projectIds: projectIds,
          page: p,
          pageSize: pageSize,
        ),
        exclude: excluded,
        want: pageSize,
        firstPage: page,
      );
      fallbackNote = {
        'from': 'tags',
        'to': 'description',
        'tagTotal': byTags.total,
        'keyword': semantic.trim(),
        'note': '按标签命中 ${byTags.total} 条，宽到等于没筛——'
            '素材库返回的是最新 50 条而不是最像的 50 条，'
            '已改用这一镜的画面描述做语义检索。'
            '想自己指定说法用 --keyword',
      };
    } else {
      filtered = excluded.isEmpty
          ? ExcludedCandidatePage(
              items: byTags.items,
              total: byTags.total,
              excludedCount: 0,
              pagesFetched: 1)
          : await searchExcluding(
              fetch: (p) => service.searchByTags(
                tagIds: effectiveIds,
                mode: tagMode,
                projectIds: projectIds,
                page: p,
                pageSize: pageSize,
              ),
              exclude: excluded,
              want: pageSize,
              firstPage: page,
            );
    }
  }

  // 时长要不要探：探了才知道「选它会变速多少」——那才是真正要判断的东西。
  // 以前一律不给，Agent 只能凭 description 猜，17 秒的坑位全靠赌
  final specs = <int, int>{};
  if (probeDurations) {
    final prober = probe ?? CandidateProbe();
    for (final c in filtered.items) {
      final spec =
          await prober.probe(materialId: c.id, previewUrl: c.previewUrl);
      if (spec?.durationMs case final ms? when ms > 0) specs[c.id] = ms;
    }
  }
  final slotMs = shotIndex == null
      ? units[unitIndex].endMs - units[unitIndex].startMs
      : shots[shotIndex].endMs - shots[shotIndex].startMs;

  emitJson({
    'context': shotIndex == null
        ? {
            'unitIndex': unitIndex,
            'slotMs': units[unitIndex].endMs - units[unitIndex].startMs,
            'unitTranscript': units[unitIndex].transcript,
            'unitTags': units[unitIndex].tags,
          }
        : shotContext(task: task, unitIndex: unitIndex, shotIndex: shotIndex),
    'total': filtered.total,
    'excludedProjects': excluded.isEmpty ? null : excluded.toList(),
    'excludedCount': excluded.isEmpty ? null : filtered.excludedCount,
    'pagesFetched': filtered.pagesFetched == 1 ? null : filtered.pagesFetched,
    'page': page,
    'pageSize': pageSize,
    'narrowed': ?narrowNote,
    'searchFallback': ?fallbackNote,
    'candidates': [
      for (final c in filtered.items)
        {
          'id': c.id,
          'name': c.name,
          // 哪个项目拍的——「换成别的项目的素材」得看得见它
          'projectId': c.projectId,
          'description': c.sceneDescription,
          'voiceover': c.voiceover,
          'tags': c.tags,
          'thumbnailUrl': c.thumbnailUrl,
          'previewUrl': c.previewUrl,
          if (specs[c.id] case final ms?) ...{
            'durationMs': ms,
            // 塞进这个坑位要多少倍速。1.0 附近最自然，
            // 离得远就是快进或慢动作——这才是要判断的东西
            'speedIfPicked':
                slotMs <= 0 ? null : (ms / slotMs * 100).round() / 100,
          },
        },
    ],
  }, out: out);
  // 结果出来再报一句：这是人判断「它找的方向对不对」的第一个信号。
  // 报完再撤——界面一闪就走等于没演
  await stage.show(
      filtered.items.isEmpty
          ? '没找到素材，要换个说法再搜'
          : '找到 ${filtered.total} 条，取回 ${filtered.items.length} 条备选',
      focus: _focus(unitIndex, shotIndex));
  stage.end();
  return 0;
}

/// 这一步要界面看哪儿。四处都要这么指，抽出来免得写歪一处
AgentFocus _focus(int unitIndex, int? shotIndex) => AgentFocus(
      module: 'workbench',
      unitIndex: unitIndex,
      shotIndex: shotIndex,
      panel: AgentPanel.findShots,
    );
