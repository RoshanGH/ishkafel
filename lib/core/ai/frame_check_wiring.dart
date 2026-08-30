import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffmpeg/process_runner.dart';
import '../ffmpeg/thumbnail_service.dart';
import '../script/shot_frame_check.dart';
import '../storage/task_media.dart';
import 'ark_chat_client.dart';
import 'frame_check.dart';
import 'frame_check_cache.dart';
import 'local_frame_check.dart';

/// 命令行这头「看一条素材的画面」的真实实现：素材本体已经下到本地，
/// 抽头中尾三帧，一次调用问清烧字和产品露出品牌。
///
/// **两条线共用这一份**（替换裂变的 `apply plans`、脚本成片的
/// `script apply shots`）。各写一份的话迟早只有一份是对的——
/// 取段在这个项目里就是这么栽了三次。
///
/// 方舟凭据缺失、或素材还没落到本地时，对应的那次检查会抛（调用方记成
/// 「未检查」）——**绝不冒充「画面没问题」**。看不成是我们的能力缺口，
/// 不是这条素材没问题。
/// [arkApiKey] 从哪来是**调用方的事**：命令行从 `.secrets/` 读，
/// 界面从凭据 provider 拿。装配逻辑只有这一份，两边共用。
ShotFrameCheck? buildShotFrameCheck({
  required String arkApiKey,
  required Directory dataDir,
  required String taskId,
}) {
  if (arkApiKey.isEmpty) return null;
  final checker = LocalVideoFrameChecker(
    checker: ArkFrameChecker(ArkChatClient(apiKey: arkApiKey)),
    thumbnails: ThumbnailService(run: const ResolvingProcessRunner().call),
    workDir: Directory(p.join(dataDir.path, 'frame_check_work')),
  );
  final media = TaskMedia(dataDir: dataDir, taskId: taskId);
  final cache = frameCheckCacheIn(dataDir);
  return (materialId, durationMs) async {
    // **先看缓存**：一条素材看一次就够，不是每个任务看一次。
    // 每次重看是拿钱换一个已经知道的答案
    if (cache.get(materialId) case final hit? when hit.framesSeen >= 3) {
      return hit;
    }
    final local = media.localMaterial(materialId);
    if (local == null) {
      throw StateError('素材还没落到本地，看不了画面');
    }
    // **时长要传下去**：头中尾三个采样点按它算。不传的话按 10 秒估，
    // 一条 30 秒的素材就只看了前 9 秒
    final result =
        await checker.check(materialId, local, durationMs: durationMs);
    cache.put(materialId, result);
    cache.prune();
    return result;
  };
}

/// 这台机器上画面自查结果存哪儿。**跨任务共用**——素材库里的素材会被
/// 反复用到，一条看一次就够
FrameCheckCache frameCheckCacheIn(Directory dataDir) =>
    FrameCheckCache(dir: Directory(p.join(dataDir.path, 'frame_checks')));
