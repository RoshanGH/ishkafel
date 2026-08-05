import 'dart:io';

import 'package:path/path.dart' as p;

import '../export/export_commands.dart';
import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import '../models/semantic_unit.dart';
import 'bgm_plan.dart';

/// 成片声音的合成器：口播 + 配音 + 配乐，合成一条完整音轨。
///
/// **预览与导出共用这一个类**。分成两套实现的话，用户在工作台里听到的和导出
/// 拿到的迟早会不一样——而预览的全部意义就是「听到的就是要交付的」。
///
/// 三条来源，按段落各取所需：
/// - 换过音色的单元 → 用生成的配音（本来就是纯人声，不含背景）
/// - 被配乐覆盖的镜头 → 用**分离出来的纯人声**（必须去掉原片自带的背景音，
///   否则新配乐与老背景两首曲子一起响）
/// - 其余段落 → 用**原混音**，一个字节都不改
///
/// 最后一条是刻意的：分离是有损的（真机实测，人声轨+背景轨与原混音的残差在
/// -27dB，听得出来）。没换配乐的地方没必要先损一道。
class AudioTrackBuilder {
  final ProcessRunner run;
  final Directory workDir;

  AudioTrackBuilder({required this.run, required this.workDir});

  /// 合成整条音轨，返回落地的 WAV 路径。
  ///
  /// [vocalsPath] 是分离出来的纯人声轨；为 null（没装分离工具或分离失败）时，
  /// 被配乐覆盖的段落只能退回原混音——新旧背景会叠在一起，由上层如实告知用户。
  Future<String> build({
    required String sourcePath,
    required List<SemanticUnit> units,
    String? vocalsPath,
    BgmPlan bgm = BgmPlan.empty,
    Map<int, String> voiceAudio = const {},
  }) async {
    workDir.createSync(recursive: true);
    final covered = bgmCoveredRanges(units, bgm);

    final parts = <String>[];
    for (final unit in units) {
      parts.addAll(await _unitParts(
        unit: unit,
        sourcePath: sourcePath,
        vocalsPath: vocalsPath,
        covered: covered,
        voiceAudio: voiceAudio,
      ));
    }

    final listFile = File(p.join(workDir.path, 'mix_list.txt'))
      ..writeAsStringSync(ExportCommands.concatList(parts));
    var out = p.join(workDir.path, 'mix_voice.wav');
    await _ffmpeg(
        ExportCommands.concat(listFile: listFile.path, out: out), '拼接声音');

    // 配乐逐段叠上去。段与段之间互不重叠，顺序无所谓
    for (var i = 0; i < bgm.segments.length; i++) {
      final segment = bgm.segments[i];
      final url = segment.material.previewUrl;
      final range = shotRangeOf(units, segment);
      if (url == null || url.isEmpty || range == null) {
        AppLog.warn('配乐「${segment.material.name}」没有可用地址或范围，这一段跳过');
        continue;
      }
      final mixed = p.join(workDir.path, 'mix_bgm_$i.wav');
      await _ffmpeg(
        ExportCommands.mixBgm(
          voice: out,
          bgm: url,
          out: mixed,
          startMs: range.$1,
          durationMs: range.$2 - range.$1,
        ),
        '配乐「${segment.material.name}」',
      );
      out = mixed;
    }
    return out;
  }

  /// 一个单元切出来的若干段声音。
  ///
  /// 换过音色的单元整段用配音；否则按**镜头**切——同一个单元里可能只有前半
  /// 段被配乐覆盖，按单元一刀切会让没覆盖的那半段也白白损一道音质。
  Future<List<String>> _unitParts({
    required SemanticUnit unit,
    required String sourcePath,
    required String? vocalsPath,
    required List<(int, int)> covered,
    required Map<int, String> voiceAudio,
  }) async {
    final voice = voiceAudio[unit.index];
    if (voice != null && File(voice).existsSync()) {
      final out = p.join(workDir.path, 'mix_u${unit.index}_voice.wav');
      await _ffmpeg(
        ExportCommands.fitVoiceAudio(
            input: voice, durationMs: unit.durationMs, out: out),
        'U${unit.index + 1} 的配音',
      );
      return [out];
    }

    final pieces = <String>[];
    final ranges = unit.shots.isEmpty
        ? [(unit.startMs, unit.endMs)]
        : [for (final s in unit.shots) (s.startMs, s.endMs)];
    for (var i = 0; i < ranges.length; i++) {
      final (start, end) = ranges[i];
      // 被配乐盖住的段落必须用纯人声，否则老背景与新配乐一起响
      final needsClean = _overlaps(covered, start, end) && vocalsPath != null;
      final out =
          p.join(workDir.path, 'mix_u${unit.index}_$i${needsClean ? '_v' : ''}.wav');
      await _ffmpeg(
        ExportCommands.trimOriginalAudio(
          source: needsClean ? vocalsPath : sourcePath,
          startMs: start,
          endMs: end,
          out: out,
        ),
        'U${unit.index + 1} 的声音',
      );
      pieces.add(out);
    }
    return pieces;
  }

  static bool _overlaps(List<(int, int)> ranges, int start, int end) {
    for (final (a, b) in ranges) {
      if (start < b && end > a) return true;
    }
    return false;
  }

  /// 配乐覆盖到的时间区间（按全片打平的镜头下标换算）
  static List<(int, int)> bgmCoveredRanges(
          List<SemanticUnit> units, BgmPlan bgm) =>
      [
        for (final segment in bgm.segments) ?shotRangeOf(units, segment),
      ];

  /// 一段配乐覆盖的镜头对应到全片的哪一段时间；越界返回 null
  static (int, int)? shotRangeOf(List<SemanticUnit> units, BgmSegment segment) {
    final flat = [
      for (final unit in units)
        for (final shot in unit.shots) shot,
    ];
    if (flat.isEmpty || segment.startShot >= flat.length) return null;
    final start = segment.startShot.clamp(0, flat.length - 1);
    final end = segment.endShot.clamp(start, flat.length - 1);
    return (flat[start].startMs, flat[end].endMs);
  }

  Future<void> _ffmpeg(List<String> args, String what) async {
    final result = await run('ffmpeg', args);
    if (result.exitCode != 0) {
      // ffmpeg 的 stderr 动辄几百行，真正的原因总在末尾
      final lines = '${result.stderr}'.trim().split('\n');
      final tail = lines.length > 3 ? lines.sublist(lines.length - 3) : lines;
      throw Exception('$what 失败：${tail.join(' / ')}');
    }
  }
}
