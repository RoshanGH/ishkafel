import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffmpeg/process_runner.dart';
import '../ffmpeg/thumbnail_service.dart';
import '../log/app_log.dart';
import 'script_doc.dart';

/// 脚本任务的封面 = **成片的第一帧**。
///
/// 成片翻新那条线的封面是原片首帧（导入时就截好了），但脚本成片没有原片——
/// 它的画面是一个个挑出来的。所以拿第一行第一镜的画面当封面：那正是这条片子
/// 开头看到的东西，最能代表它。
///
/// 之前这里什么都没有，于是列表页上一条排了 27 句、配好镜头的片子和一个
/// 空任务长得一模一样（都是黑块），人分不出哪条做过、哪条还没开始。
///
/// 按内容指纹缓存：第一镜没换就不重抽（不做一次性的脏活）。
/// 产物落 `<dataDir>/covers/<taskId>.jpg`，与成片翻新同一个目录规矩，
/// TaskArtifacts 删任务时随目录清走。
Future<String?> ensureScriptCover({
  required ScriptDoc doc,
  required Directory dataDir,
  required String taskId,
  required String? Function(int materialId) localPathOf,
  ProcessRunner run = systemProcessRunner,
}) async {
  final shot = _firstShot(doc);
  if (shot == null) return null;
  final source = shot.localSource ?? localPathOf(shot.materialId);
  if (source == null || !File(source).existsSync()) return null;

  final coversDir = Directory(p.join(dataDir.path, 'covers'));
  final out = p.join(coversDir.path, '$taskId.jpg');
  // 指纹：第一镜换了、或取段起点挪了，封面才需要重抽
  final stampFile = File(p.join(coversDir.path, '$taskId.cover-stamp'));
  final stamp = '${shot.materialId}|${shot.trimStartMs}|$source';
  if (File(out).existsSync() &&
      stampFile.existsSync() &&
      stampFile.readAsStringSync() == stamp) {
    return out;
  }

  try {
    await coversDir.create(recursive: true);
    await ThumbnailService(run: run).extractCover(
      videoPath: source,
      outPath: out,
      // 从这一镜实际用到的那一刻取，而不是素材开头——取过段的镜头，
      // 开头那一帧根本不会出现在成片里
      atSeconds: shot.trimStartMs / 1000,
    );
    stampFile.writeAsStringSync(stamp);
    return out;
  } catch (e) {
    AppLog.warn('脚本封面抽取失败（$taskId）：$e');
    return null;
  }
}

/// 第一个有画面的镜头。前面几行可能还没配镜头，往后找
LineShot? _firstShot(ScriptDoc doc) {
  for (final line in doc.lines) {
    for (final shot in line.shots) {
      return shot;
    }
  }
  return null;
}
