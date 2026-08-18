import 'dart:io';

import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/miaoa/tag_id_resolver.dart';
import '../../core/storage/file_task_repository.dart';
import '../candidate_context.dart';
import '../cli_output.dart';

/// `ishkafel candidates <task> --unit <i> [--shot <j>]`
///
/// 返回候选素材 + **上下文**。候选带 miaoa 的图片 URL、不落地——按 spec
/// 的决定，看不看图、怎么去重、选哪几个，全是调用方的判断。
///
/// **候选不带时长**：`CandidateMaterial` 没有这个字段，miaoa 的检索结果不含
/// 时长；GUI 上那个「+1.5s」是另外逐条探测出来的（每条一次网络 + ffprobe）。
/// 在候选列表里同步做会让这条命令慢到不可用。变速可行性的判断放到方案提交
/// 时做，那时只需要探测被真正选中的那几条。
Future<int> runCandidatesCommand({
  required List<String> rest,
  required Directory dataDir,
  required int? unitIndex,
  required int? shotIndex,
  int pageSize = 50,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty || unitIndex == null) {
    sink.writeln('用法：ishkafel candidates <任务 id> --unit <单元下标> [--shot <镜头下标>]');
    return exitBadUsage;
  }

  final task = await FileTaskRepository(dataDir).findById(rest.first);
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

  // 打标产出的是标签**名**（受控词表就是名字），而 miaoa 的检索只收标签
  // **id**，中间必须有一次映射，映射表来自任务选定的标签组
  final resolver = TagIdResolver(MiaoaTagService());
  await resolver.loadAll({
    for (final g in task.unitTagGroups) g.id,
    for (final g in task.shotTagGroups) g.id,
  });
  if (resolver.loadFailure case final failure?) {
    sink.writeln(failure);
    return 1;
  }

  final tagNames =
      shotIndex == null ? units[unitIndex].tags : shots[shotIndex].tags;
  final tagIds = resolver.idsOf(tagNames);
  if (tagIds.isEmpty) {
    sink.writeln(tagNames.isEmpty
        ? '这一层还没有标签，无法按标签检索。先确认任务选了标签组、且已完成打标'
        : '这些标签在素材库里找不到对应项（可能已被改名或删除）：${tagNames.join('、')}');
    return exitNotFound;
  }

  final page = await MiaoaContentService()
      .searchByTags(
    tagIds: tagIds,
    mode: 'or',
    projectIds: [?task.project?.id],
    pageSize: pageSize,
  );

  emitJson({
    'context': shotIndex == null
        ? {
            'unitIndex': unitIndex,
            'slotMs': units[unitIndex].endMs - units[unitIndex].startMs,
            'unitTranscript': units[unitIndex].transcript,
            'unitTags': units[unitIndex].tags,
          }
        : shotContext(task: task, unitIndex: unitIndex, shotIndex: shotIndex),
    'total': page.total,
    'candidates': [
      for (final c in page.items)
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
