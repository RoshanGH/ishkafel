import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/log/app_log.dart';

/// 抽一帧到本地。返回 true = 抽成功
typedef FrameExtractor = Future<bool> Function(
    String videoPath, String outPath, int atMs);

/// 给 Agent 看的画面帧存在哪。
///
/// 存在理由是用户的一句话：「**就像人看到这个东西一样，Agent 也要看到
/// 这个东西**，然后拿这个东西去搜索出对应的分镜。」
///
/// 现在给 Agent 的候选只有 `thumbnailUrl`——miaoa 的签名地址，会过期，
/// 而且 Agent 读不了远程图。它需要的是**本地路径**：拿到路径就能直接
/// 看图，像人一样判断「这一镜像不像」。
///
/// 按 `视频路径 + 时刻` 的指纹命名：同一段只抽一次，改了才重抽——
/// 每次进来重抽几十帧，用户看到的是「这软件真慢」。
String framePath(Directory dataDir,
    {required String videoPath, required int atMs}) {
  final key = sha1.convert(utf8.encode('$videoPath@$atMs')).toString();
  return p.join(dataDir.path, 'agent_frames', '${key.substring(0, 16)}.jpg');
}

/// 确保这一帧在本地，返回路径；抽不出来返回 null。
///
/// **抽不出来就说抽不出来**，不给一个指向空文件的路径——Agent 拿着读不出
/// 东西的路径，只会以为是自己用错了。
Future<String?> ensureFrame({
  required Directory dataDir,
  required String videoPath,
  required int atMs,
  required FrameExtractor extract,
}) async {
  final out = framePath(dataDir, videoPath: videoPath, atMs: atMs);
  final f = File(out);
  if (f.existsSync() && f.lengthSync() > 0) return out;
  // 目录在这儿建好：让每个抽帧实现各记一遍，迟早有一个忘了
  Directory(p.dirname(out)).createSync(recursive: true);
  try {
    final ok = await extract(videoPath, out, atMs);
    if (!ok) return null;
    return f.existsSync() && f.lengthSync() > 0 ? out : null;
  } catch (e) {
    AppLog.warn('给 Agent 抽帧失败（$videoPath@$atMs）：$e');
    return null;
  }
}
