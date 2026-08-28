import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../agent_frames.dart';
import '../cli_output.dart';

/// `ishkafel peek --video <路径> [--at 2000] [--ats 0,30000,70000]`
///
/// **让 Agent 亲眼看画面**，而不是凭 description 猜。
///
/// 由来：验收 Agent 走完整条线之后说「U3S2 那个 17.3 秒的坑位我是纯赌的」
/// 「画面对不对不是我验的，是你抽帧看的」。人能做的三件事——看候选长什么样、
/// 看它多长、看导出来的成片对不对——它一件都做不了。
///
/// 抽出来的帧按内容指纹缓存，同一个位置看第二次不再跑 ffmpeg。
Future<int> runPeekCommand({
  required List<String> rest,
  required Directory dataDir,
  String? videoPath,
  int? atMs,
  String? atMsList,
  StringSink? out,
  StringSink? err,
  FrameExtractor? extract,
  Future<int> Function(String path)? probeDurationMs,
}) async {
  final sink = err ?? stderr;
  final path = videoPath ?? (rest.isNotEmpty ? rest.first : null);
  if (path == null || path.trim().isEmpty) {
    sink.writeln('用法：ishkafel peek --video <视频路径> [--at 2000] '
        '[--ats 0,30000,70000]\n'
        '看导出来的成片对不对、看一条素材长什么样，都用它。'
        '抽出来的帧路径会给你，直接打开看');
    return exitBadUsage;
  }
  if (!File(path).existsSync()) {
    sink.writeln('找不到这个文件：$path');
    return exitNotFound;
  }

  final probe = probeDurationMs ?? _probeDuration;
  final total = await probe(path);
  if (total <= 0) {
    sink.writeln('量不出这个文件的时长，它可能不是视频，或者已经损坏：$path');
    return exitFailed;
  }

  final points = <int>[
    for (final piece in (atMsList ?? '').split(','))
      ?int.tryParse(piece.trim()),
  ];
  if (points.isEmpty) points.add(atMs ?? 1000);

  final beyond = points.where((ms) => ms >= total).toList();
  if (beyond.isNotEmpty) {
    // 悄悄给最后一帧会让人以为「这个时间点就长这样」，判断全歪
    sink.writeln('这些时间点超出了片长：${beyond.join('、')} 毫秒。'
        '这条片子只有 ${(total / 1000).toStringAsFixed(1)} 秒');
    return exitBadUsage;
  }

  final extractor = extract ?? _defaultExtract;
  final frames = <Map<String, dynamic>>[];
  final failed = <String>[];
  for (final ms in points) {
    final frame = await ensureFrame(
      dataDir: dataDir,
      videoPath: path,
      atMs: ms,
      extract: extractor,
    );
    if (frame == null) {
      failed.add('$ms 毫秒处抽帧失败');
      continue;
    }
    frames.add({'atMs': ms, 'framePath': frame});
  }
  if (frames.isEmpty) {
    sink.writeln('一帧都没抽出来：${failed.join('；')}');
    return exitFailed;
  }

  emitJson({
    'videoPath': path,
    'durationMs': total,
    // 单点看的时候直接把路径摊平，省得为一帧再解一层
    if (frames.length == 1) 'framePath': frames.single['framePath'],
    if (frames.length == 1) 'atMs': frames.single['atMs'],
    'frames': frames,
    if (failed.isNotEmpty) 'failed': failed,
    'next': '直接打开 framePath 看图。一帧看不出片子对不对——'
        '用 --ats 挑几个时间点，开头、中间、结尾各看一眼',
  }, out: out);
  return 0;
}

Future<bool> _defaultExtract(String video, String outPath, int atMs) async {
  await ThumbnailService(run: const ResolvingProcessRunner().call)
      .extractCover(videoPath: video, outPath: outPath, atSeconds: atMs / 1000);
  return true;
}

Future<int> _probeDuration(String path) async {
  try {
    final r = await const ResolvingProcessRunner().call('ffprobe', [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=nw=1:nk=1',
      path,
    ]);
    final seconds = double.tryParse('${r.stdout}'.trim());
    return seconds == null ? 0 : (seconds * 1000).round();
  } catch (_) {
    return 0;
  }
}
