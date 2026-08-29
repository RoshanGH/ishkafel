import 'dart:io';

import '../core/ffmpeg/process_runner.dart';
import '../core/ffmpeg/thumbnail_service.dart';
import 'agent_frames.dart';

/// 原片这一镜长什么样——**抽一张本地图给 Agent 看**。
///
/// 脚本成片那条线挑镜头时直接给 `framePath`，替换裂变只给文字描述：
/// Agent 得自己再跑一次 peek、还得自己算这一镜从第几毫秒开始。
/// 「凡是人在界面上看得见的，你都能拿到本地文件」——人点开那一镜就看见了。
///
/// 取中点：两端常踩在转场上，抽出来是糊的。抽过的按内容指纹复用。
/// 失败返回 null 而不是抛——挑素材不该因为看不到原片图就整个失败。
Future<String?> shotFramePath({
  required Directory dataDir,
  required String? sourcePath,
  required int startMs,
  required int endMs,
  FrameExtractor? extract,
}) async {
  if (sourcePath == null || sourcePath.isEmpty) return null;
  final at = startMs + (endMs - startMs) ~/ 2;
  try {
    return await ensureFrame(
      dataDir: dataDir,
      videoPath: sourcePath,
      atMs: at,
      extract: extract ?? _defaultExtract,
    );
  } catch (_) {
    return null;
  }
}

Future<bool> _defaultExtract(String video, String outPath, int atMs) async {
  await ThumbnailService(run: const ResolvingProcessRunner().call)
      .extractCover(videoPath: video, outPath: outPath, atSeconds: atMs / 1000);
  return true;
}
