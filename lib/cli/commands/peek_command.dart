import 'dart:io';


import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/miaoa/material_downloader.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_media.dart';
import '../../core/storage/task_seq.dart';
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

  /// 看候选素材：`peek <任务> --materials 65071,65073`。
  /// 没落到本地的会先取下来——「有 URL 但没有命令能读」等于没给
  String? materials,
  int? atMs,
  String? atMsList,
  StringSink? out,
  StringSink? err,
  FrameExtractor? extract,
  Future<int> Function(String path)? probeDurationMs,
}) async {
  final sink = err ?? stderr;
  if ((materials ?? '').trim().isNotEmpty) {
    return _peekMaterials(
      taskRef: rest.isNotEmpty ? rest.first : null,
      materials: materials!,
      dataDir: dataDir,
      out: out,
      sink: sink,
      extract: extract,
    );
  }
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

/// 看候选素材长什么样。与脚本成片线的 `script peek --materials` 同一件事——
/// 那条线一直有，替换裂变这条线一直没有，于是 Agent 只能自己 curl
/// （验收 Agent 真这么干了，并且指出手册让它「读 thumbnailUrl」
/// 却没给读的手段）
Future<int> _peekMaterials({
  required String? taskRef,
  required String materials,
  required Directory dataDir,
  required StringSink sink,
  StringSink? out,
  FrameExtractor? extract,
}) async {
  if (taskRef == null) {
    sink.writeln('要指定任务：ishkafel peek <任务 id> --materials 65071,65073');
    return exitBadUsage;
  }
  final task = await resolveTaskRef(FileTaskRepository(dataDir), taskRef);
  if (task == null) {
    sink.writeln('没有这个任务：$taskRef');
    return exitNotFound;
  }
  final ids = <int>[
    for (final piece in materials.split(',')) ?int.tryParse(piece.trim()),
  ];
  if (ids.isEmpty) {
    sink.writeln('没说要看哪几条：--materials 65071,65073');
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
        // 第 1 秒：开头常有转场和黑帧，拿它当封面会看不出画面
        atMs: 1000,
        extract: extract ?? _defaultExtract,
      );
      if (frame == null) {
        failed.add('$id（抽帧失败）');
        continue;
      }
      frames.add({
        'materialId': id,
        'framePath': frame,
        'videoPath': local,
      });
    } catch (e) {
      // 一条失败不挡其余：能看的那几条照样能帮 Agent 下判断
      failed.add('$id（$e）');
    }
  }
  if (frames.isEmpty) {
    sink.writeln('一条都没看成：${failed.join('；')}');
    return exitFailed;
  }
  emitJson({
    'frames': frames,
    if (failed.isNotEmpty) 'failed': failed,
    'next': '直接打开 framePath 看图，像人一样判断这一镜像不像。'
        '想看这条素材更多画面就用 --video <videoPath> --ats <时间点>',
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
