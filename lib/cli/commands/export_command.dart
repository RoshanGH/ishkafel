import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/audio/bgm_cache_factory.dart';
import '../../core/audio/material_vocal_cache.dart';
import '../../core/audio/vocal_separator.dart';
import '../../core/export/export_runner.dart';
import '../../core/export/export_spec.dart';
import '../../core/ffmpeg/ffprobe_service.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/miaoa/material_downloader.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/models/export_record.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../cli_output.dart';
import '../plan_submission.dart';
import 'apply_command.dart';

/// `ishkafel export <task> [--out <目录>]`
///
/// 按 `apply plans` 提交的方案**逐条导出**，不做笛卡尔积。
///
/// **先说代价、但不设闸门**：会导几条、大概多久，如实输出；要不要继续是
/// 调用方的判断——我是工具，你来调用我（spec 第一节）。
Future<int> runExportCommand({
  required List<String> rest,
  required Directory dataDir,
  String? outputDir,
  String? resolution,
  String? fps,
  String? bitrate,
  String? codec,
  String? format,
  String holder = 'agent',
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel export <任务 id> [--out <目录>] '
        '[--resolution 480|720|1080|1440|2160] [--fps 24|25|30|50|60] '
        '[--bitrate recommended|higher|lower|<kbps>] '
        '[--codec h264|hevc] [--format mp4|mov]');
    return exitBadUsage;
  }

  // 规格参数逐个校验，认不出就报错——静默用默认值会让调用方以为生效了
  final spec = _parseSpec(
    resolution: resolution,
    fps: fps,
    bitrate: bitrate,
    codec: codec,
    format: format,
    sink: sink,
  );
  if (spec == null) return exitBadUsage;
  final id = rest.first;

  final repository = FileTaskRepository(dataDir);
  final task = await repository.findById(id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  final units = task.units;
  if (units == null) {
    sink.writeln('这个任务还没分析完，没法导出');
    return exitNotFound;
  }

  final raw = readSubmittedPlans(dataDir, id);
  if (raw == null) {
    sink.writeln('还没有提交方案。先跑 ishkafel apply plans $id --file <方案.json>');
    return exitNotFound;
  }
  final validation = parsePlans(jsonDecode(raw), task);
  if (!validation.ok) {
    // 提交时校验过一次，这里再过一遍——中间任务可能被改过（比如切分变了）
    sink.writeln('已提交的方案对不上现在的任务了：');
    for (final problem in validation.errors) {
      sink.writeln('· $problem');
    }
    return exitBadUsage;
  }

  final lock = TaskLockFile(dataDir: dataDir, taskId: id);
  if (!lock.acquire(holder)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，导不了');
    return exitLocked;
  }

  final dest = Directory(outputDir ??
      p.join(Platform.environment['HOME'] ?? '.', 'Desktop', 'ishkafel-$id'));
  final combos = [
    for (var i = 0; i < validation.plans.length; i++)
      toCombination(validation.plans[i], units, index: i),
  ];

  // 代价先说清楚——但不拦。要不要继续是调用方的判断
  sink.writeln('将导出 ${combos.length} 条到 ${dest.path}'
      '（${spec.width}×${spec.height} · ${spec.fps}fps · '
      '${spec.kbps ~/ 1000} Mbps · ${spec.encoderName} · ${spec.fileExtension}）');

  final runner = ExportRunner(
    run: const ResolvingProcessRunner().call,
    workDir: Directory(p.join(dataDir.path, 'export_work', id)),
    resolveBgm: bgmCache(dataDir).fetch,
    probeDurationMs: (path) async =>
        (await FfprobeService(run: const ResolvingProcessRunner().call)
                .probe(path))
            .duration
            .inMilliseconds,
    fetchMaterial: MaterialDownloader(
      content: MiaoaContentService(),
      cacheDir: Directory(p.join(dataDir.path, 'material_cache')),
    ).fetch,
    // 整体替换的段落铺了配乐时用素材的纯人声——与 GUI 同一条规则
    separateMaterial: MaterialVocalCache(
      separator: VocalSeparator(
        binary: resolveVocalSeparatorBinary(),
        modelDir: Directory(p.join(dataDir.path, 'separator_models')),
      ),
      cacheDir: Directory(p.join(dataDir.path, 'material_vocals')),
    ).vocalsOf,
  );

  final outcomes = await runner.exportCombinations(
    combos: combos,
    spec: spec,
    sourcePath: task.sourcePath,
    units: units,
    replacements: task.replacements ?? const [],
    outputDir: dest,
    bgm: task.bgm,
    vocalsPath: task.vocalsPath,
    // 镜头替换的切片上重渲台词字幕（原片字幕烧在被换掉的画面里）
    subtitleSentences: task.asrSentences ?? const [],
    onProgress: (done, total, what) =>
        sink.writeln('[$done/$total] $what'),
  );

  final succeeded = outcomes.where((o) => o.failure == null).length;
  // 导出历史进任务：人在 app 里要能看到「哪天导了几条、在哪儿」
  await repository.save(task.copyWith(exports: [
    ...task.exports,
    ExportRecord(
      at: DateTime.now(),
      total: outcomes.length,
      succeeded: succeeded,
      outputDir: dest.path,
    ),
  ]));
  lock.release(holder);

  emitJson({
    'outputDir': dest.path,
    'total': outcomes.length,
    'succeeded': succeeded,
    'results': [
      for (var i = 0; i < outcomes.length; i++)
        {
          'name': validation.plans[i].name,
          'path': outcomes[i].path,
          'failure': outcomes[i].failure,
        },
    ],
  }, out: out);
  // 有失败的就非零退出：调用方不该靠解析 JSON 才发现出了问题
  return succeeded == outcomes.length ? 0 : 1;
}


/// 把命令行给的规格参数拼成 [ExportSpec]。任何一个认不出都返回 null 并报错
ExportSpec? _parseSpec({
  required String? resolution,
  required String? fps,
  required String? bitrate,
  required String? codec,
  required String? format,
  required StringSink sink,
}) {
  var spec = ExportSpec.standard;
  if (resolution != null) {
    final side = int.tryParse(resolution);
    if (side == null ||
        !ExportSpec.resolutions.any((r) => r.shortSide == side)) {
      sink.writeln('认不出分辨率「$resolution」。可用：'
          '${ExportSpec.resolutions.map((r) => r.shortSide).join(' / ')}（短边）');
      return null;
    }
    spec = spec.copyWith(shortSide: side);
  }
  if (fps != null) {
    final value = int.tryParse(fps);
    if (value == null || !ExportSpec.frameRates.contains(value)) {
      sink.writeln('认不出帧率「$fps」。可用：${ExportSpec.frameRates.join(' / ')}');
      return null;
    }
    spec = spec.copyWith(fps: value);
  }
  if (bitrate != null) {
    switch (bitrate) {
      case 'recommended':
        spec = spec.copyWith(bitrate: BitrateMode.recommended);
      case 'higher':
        spec = spec.copyWith(bitrate: BitrateMode.higher);
      case 'lower':
        spec = spec.copyWith(bitrate: BitrateMode.lower);
      default:
        final kbps = int.tryParse(bitrate);
        if (kbps == null || kbps <= 0 || kbps > ExportSpec.maxCustomKbps) {
          sink.writeln('认不出码率「$bitrate」。可用：recommended / higher / '
              'lower，或直接给 kbps 数字（上限 ${ExportSpec.maxCustomKbps}）');
          return null;
        }
        spec = spec.copyWith(
            bitrate: BitrateMode.custom, customKbps: kbps);
    }
  }
  if (codec != null) {
    final value =
        VideoCodec.values.where((c) => c.name == codec).firstOrNull;
    if (value == null) {
      sink.writeln('认不出编码「$codec」。可用：h264 / hevc');
      return null;
    }
    spec = spec.copyWith(codec: value);
  }
  if (format != null) {
    final value =
        ContainerFormat.values.where((f) => f.name == format).firstOrNull;
    if (value == null) {
      sink.writeln('认不出格式「$format」。可用：mp4 / mov');
      return null;
    }
    spec = spec.copyWith(format: value);
  }
  return spec;
}
