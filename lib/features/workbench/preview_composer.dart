import 'dart:io';


import '../../core/export/composed_timeline.dart';
import '../../core/export/export_commands.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/rendered_cache.dart';
import '../../core/log/app_log.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/replacement/replacement_plan.dart';

/// 预览合成的产物
class ComposedPreview {
  /// 合成出来的片子；为 null 表示「没有替换，照旧播原片」
  final String? videoPath;

  /// 成片的时间轴。播放头要靠它把成片时刻映射回原片时刻
  final ComposedTimeline timeline;

  const ComposedPreview({required this.videoPath, required this.timeline});
}

/// 把「原片 + 各槽位的预览版」合成一条能播的片子。
///
/// **为什么必须真的合成**：预览此前是「播原片文件 + 挂一条外挂音轨」，画面
/// 永远是原片。镜头替换只换画面不动声音，听着还对；但整体替换会把这一段的
/// 声音和时长都换掉，画面还停在原片上，从那一段之后声画全错位。
///
/// 每个槽位可以选多个候选（导出时各出一条变体），其中一个标为**预览版**
/// （见 [UnitReplacement.wholePreviewId]）——预览放的就是它，于是有了唯一
/// 确定的一条片子。
///
/// **段落级缓存**：只有改动的那一段重渲染，其余复用。每改一次就把整条片子
/// 重跑一遍的话，预览会慢到没法用。
///
/// 缓存**认磁盘上的文件**，不只认内存里那张表。真机上 51 个镜头合一遍要四
/// 分钟，而每次合成都新建一个 [PreviewComposer]，内存表当场作废——于是重开
/// 一次任务就把四十多段全重渲染一遍，用户看到的是「正在合成预览音轨」永远
/// 挂在那儿。切片文件名由段落指纹决定，先写 `.part` 再改名，所以磁盘上存在
/// 的那份一定是完整的，可以放心直接用。
class PreviewComposer {
  final ProcessRunner run;
  final Directory workDir;
  final Future<String> Function(int candidateId) fetchMaterial;

  /// 读候选素材有多长——整体替换要用它算成片时长，镜头替换要用它算变速倍率
  final Future<int?> Function(String path)? probeDurationMs;

  /// 渲染进度（已完成段数 / 总段数）。四十多段要跑几分钟，只说「稍后就能
  /// 听到」等于让用户干等着猜还有多久
  void Function(int done, int total)? onProgress;

  int _done = 0;
  int _total = 0;

  /// 每一件产物按**内容指纹**命名并复用（见 [RenderedCache]）
  late final RenderedCache _cache = RenderedCache(dir: workDir, run: run);

  PreviewComposer({
    required this.run,
    required this.workDir,
    required this.fetchMaterial,
    this.probeDurationMs,
    this.onProgress,
  });

  Future<ComposedPreview> compose({
    required String sourcePath,
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    required String? audioPath,
  }) async {
    final picks = _previewPicks(units, replacements);
    if (picks.isEmpty) {
      // 一处替换都没有：合出来的就是原片，白跑一遍 ffmpeg 是浪费
      return ComposedPreview(
        videoPath: null,
        timeline:
            ComposedTimeline.of(units: units, wholeDurations: const {}),
      );
    }

    workDir.createSync(recursive: true);
    _cache.resetTouched();
    final wholeDurations = <int, int>{};
    final parts = <String>[];
    _done = 0;
    _total = _segmentCount(units, picks, replacements);

    for (final unit in units) {
      final pick = picks[unit.index];
      if (pick != null && pick.shotIndex == null) {
        // 整体替换：整段来自候选，原样接上
        final path = await fetchMaterial(pick.candidateId);
        final ms = await _probe(path);
        if (ms != null) wholeDurations[unit.index] = ms;
        parts.add(await _clip(
          key: 'whole|$path',
          prefix: 'pv_whole_${unit.index}',
          args: (out) =>
              ExportCommands.wholeReplacementVideo(input: path, out: out),
          what: 'U${unit.index + 1} 的整体替换画面',
        ));
        continue;
      }
      // 逐镜头：换过的按倍率变速，没换的切原片
      for (var s = 0; s < unit.shots.length; s++) {
        final shot = unit.shots[s];
        final shotPick = _shotPick(replacements, unit.index, s);
        if (shotPick == null) {
          parts.add(await _clip(
            key: 'src|$sourcePath|${shot.startMs}|${shot.endMs}',
            prefix: 'pv_src_${shot.startMs}_${shot.endMs}',
            args: (out) => ExportCommands.trimOriginalVideo(
                source: sourcePath,
                startMs: shot.startMs,
                endMs: shot.endMs,
                out: out),
            what: 'U${unit.index + 1} 的原片画面',
          ));
          continue;
        }
        final path = await fetchMaterial(shotPick);
        final slotMs = shot.endMs - shot.startMs;
        final candidateMs = await _probe(path);
        parts.add(await _clip(
          key: 'shot|$path|$slotMs|$candidateMs',
          prefix: 'pv_shot_${shot.startMs}_${shot.endMs}',
          args: (out) => ExportCommands.fitCandidateVideo(
            input: path,
            durationMs: slotMs,
            // 变速倍率要用候选的真实时长；探不出来就退回裁/冻帧
            candidateDurationMs: candidateMs,
            out: out,
          ),
          what: 'U${unit.index + 1} 的镜头替换画面',
        ));
      }
    }

    final concatKey = 'concat|${parts.join('|')}';
    final listFile = _cache.writeText(
        key: concatKey,
        prefix: 'preview_list',
        extension: 'txt',
        content: ExportCommands.concatList(parts));
    final silent = await _cache.render(
      key: concatKey,
      prefix: 'preview_silent',
      extension: 'mp4',
      args: (out) => ExportCommands.concat(listFile: listFile, out: out),
      what: '拼接预览画面',
    );

    var video = silent;
    if (audioPath != null && File(audioPath).existsSync()) {
      video = await _cache.render(
        key: 'mux|$concatKey|$audioPath',
        prefix: 'preview',
        extension: 'mp4',
        args: (out) =>
            ExportCommands.mux(video: silent, audio: audioPath, out: out),
        what: '预览画面与声音合成',
      );
    }

    // 换一次方案就多攒一套，不清就只增不减；「这份预览是按什么方案合的」
    // 那份存档不能删（它就在这个目录里）
    _cache.keepOnly(protect: protectedPaths);

    return ComposedPreview(
      videoPath: video,
      timeline:
          ComposedTimeline.of(units: units, wholeDurations: wholeDurations),
    );
  }

  /// 这一次要出多少段。整体替换的单元算一段，其余按镜头数算
  static int _segmentCount(
    List<SemanticUnit> units,
    Map<int, ({int candidateId, int? shotIndex})> picks,
    List<UnitReplacement> replacements,
  ) {
    var total = 0;
    for (final unit in units) {
      final pick = picks[unit.index];
      total += pick != null && pick.shotIndex == null ? 1 : unit.shots.length;
    }
    return total;
  }

  /// 各单元的预览版（整体替换）。镜头层的走 [_shotPick]
  static Map<int, ({int candidateId, int? shotIndex})> _previewPicks(
      List<SemanticUnit> units, List<UnitReplacement> replacements) {
    final out = <int, ({int candidateId, int? shotIndex})>{};
    for (var i = 0; i < units.length && i < replacements.length; i++) {
      final r = replacements[i];
      if (r.mode == ReplacementMode.whole && r.wholePreviewId != null) {
        out[i] = (candidateId: r.wholePreviewId!, shotIndex: null);
      } else if (r.mode == ReplacementMode.perShot &&
          r.shotPreviewIds.isNotEmpty) {
        // 这个单元有镜头被替换：标记一下，具体哪几个镜头由 _shotPick 决定
        out[i] = (candidateId: -1, shotIndex: -1);
      }
    }
    return out;
  }

  static int? _shotPick(
      List<UnitReplacement> replacements, int unitIndex, int shotIndex) {
    if (unitIndex >= replacements.length) return null;
    final r = replacements[unitIndex];
    if (r.mode != ReplacementMode.perShot) return null;
    return r.shotPreviewId(shotIndex);
  }

  Future<int?> _probe(String path) async {
    final probe = probeDurationMs;
    if (probe == null) return null;
    try {
      final ms = await probe(path);
      return ms != null && ms > 0 ? ms : null;
    } catch (e) {
      AppLog.warn('预览：读不出 $path 的时长：$e');
      return null;
    }
  }

  /// 渲染一段并缓存。同一段在多次 compose 之间复用——用户改一个槽位时，
  /// 其余段落不该重渲染
  Future<String> _clip({
    required String key,
    required String prefix,
    required List<String> Function(String out) args,
    required String what,
  }) async {
    final before = _cache.touched.length;
    final path = await _cache.render(
        key: key, prefix: prefix, extension: 'mp4', args: args, what: what);
    // 命中缓存的不算进度——那一段本来就不用等
    if (_cache.touched.length > before) onProgress?.call(++_done, _total);
    return path;
  }

  /// 清理时要保护的文件（调用方放在同一个目录里的存档）
  Set<String> protectedPaths = const {};
}
