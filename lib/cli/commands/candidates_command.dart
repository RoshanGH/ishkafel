import 'dart:io';

import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/miaoa/tag_id_resolver.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../../features/picking/tag_hit_probe.dart';
import '../../features/picking/tag_query_narrowing.dart';
import '../../features/picking/tag_result_usability.dart';
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

  final service = contentService ?? MiaoaContentService();
  final projectIds = [?task.project?.id];

  final CandidatePage result;
  Map<String, Object?>? narrowNote;
  Map<String, Object?>? fallbackNote;
  int? libraryTotal;
  if (keyword != null && keyword.trim().isNotEmpty) {
    // 画面描述语义搜：标签打不上（话术标签几乎没人打）时的第二条路
    result = await service.searchByDescription(
      keyword: keyword.trim(),
      projectIds: projectIds,
      page: page,
      pageSize: pageSize,
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
      libraryTotal: libraryTotal ?? byTags.total,
      returned: byTags.items.length,
      pageSize: pageSize,
    );
    final semantic = (shotIndex == null
            ? units[unitIndex].transcript
            : shots[shotIndex].description) ??
        '';
    if (!usable && semantic.trim().isNotEmpty) {
      result = await service.searchByDescription(
        keyword: semantic.trim(),
        projectIds: projectIds,
        page: page,
        pageSize: pageSize,
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
      result = byTags;
    }
  }

  emitJson({
    'context': shotIndex == null
        ? {
            'unitIndex': unitIndex,
            'slotMs': units[unitIndex].endMs - units[unitIndex].startMs,
            'unitTranscript': units[unitIndex].transcript,
            'unitTags': units[unitIndex].tags,
          }
        : shotContext(task: task, unitIndex: unitIndex, shotIndex: shotIndex),
    'total': result.total,
    'page': page,
    'pageSize': pageSize,
    'narrowed': ?narrowNote,
    'searchFallback': ?fallbackNote,
    'candidates': [
      for (final c in result.items)
        {
          'id': c.id,
          'name': c.name,
          'description': c.sceneDescription,
          'voiceover': c.voiceover,
          'tags': c.tags,
          'thumbnailUrl': c.thumbnailUrl,
          'previewUrl': c.previewUrl,
        },
    ],
  }, out: out);
  return 0;
}
