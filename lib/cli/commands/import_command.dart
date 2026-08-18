import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/ffmpeg/ffprobe_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/storage/file_task_repository.dart';
import '../../features/import_flow/import_service.dart';
import '../cli_output.dart';

/// `ishkafel import <视频> [--tag-groups <id,id>]`
///
/// 建任务并落库。**标签组要在这一步定**：它是打标的受控词表，没有它 AI
/// 打不出标签，后面挑替换素材时就没有标签可用（这条静默失败链在真机上
/// 撞过，见 spec）。
///
/// 不给 `--tag-groups` 时**明确警告**而不是默默建一个残废的任务。
Future<int> runImportCommand({
  required List<String> rest,
  required Directory dataDir,
  String? tagGroups,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel import <视频文件> [--tag-groups <标签组 id，逗号分隔>]');
    return exitBadUsage;
  }
  final path = rest.first;
  if (!File(path).existsSync()) {
    sink.writeln('找不到这个文件：$path');
    return exitNotFound;
  }

  final ids = <int>[
    for (final piece in (tagGroups ?? '').split(',')) ?int.tryParse(piece.trim()),
  ];

  var groups = <TagGroupRef>[];
  if (ids.isNotEmpty) {
    try {
      final all = await MiaoaTagService()
          .listGroups();
      groups = [
        for (final g in all)
          if (ids.contains(g.id)) TagGroupRef(id: g.id, name: g.name),
      ];
      final missing = ids.where((id) => !groups.any((g) => g.id == id));
      if (missing.isNotEmpty) {
        // 不能默默少几个：受控词表少一块，那一层就打不出对应的标签
        sink.writeln('这些标签组在当前企业下找不到：${missing.join('、')}。'
            '标签组是按企业分的，确认一下 miaoa 当前企业是否正确');
        return exitNotFound;
      }
    } catch (e) {
      sink.writeln('读不到标签组：$e');
      return exitEnv;
    }
  } else {
    sink.writeln('警告：没有指定标签组，这条任务不会打标——'
        '后面挑替换素材时会没有标签可用。可用 ishkafel tag-groups 查看可选项');
  }

  final task = await ImportService(
    repository: FileTaskRepository(dataDir),
    ffprobe: FfprobeService(),
    thumbnails: ThumbnailService(),
    coversDir: Directory(p.join(dataDir.path, 'covers')),
  ).importLocalFile(
    path,
    unitTagGroups: groups,
    shotTagGroups: groups,
  );

  emitJson({
    'id': task.id,
    'name': task.name,
    'durationMs': task.videoInfo?.duration.inMilliseconds,
    'tagGroups': [for (final g in groups) g.name],
    'next': 'ishkafel analyze ${task.id}',
  }, out: out);
  return 0;
}

/// `ishkafel tag-groups` —— 当前企业下有哪些标签组，供 import 选用
Future<int> runTagGroupsCommand({StringSink? out, StringSink? err}) async {
  try {
    final groups =
        await MiaoaTagService().listGroups();
    emitJson({
      'groups': [
        for (final g in groups) {'id': g.id, 'name': g.name},
      ],
    }, out: out);
    return 0;
  } catch (e) {
    (err ?? stderr).writeln('读不到标签组：$e');
    return 1;
  }
}
