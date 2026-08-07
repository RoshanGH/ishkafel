import 'dart:io';

import 'package:path/path.dart' as p;

import '../export/composed_timeline.dart';
import '../export/export_commands.dart';
import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import '../models/semantic_unit.dart';
import 'bgm_cache.dart';
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
/// 合成结果：落地路径 + 这一次哪几段配乐没铺上。
///
/// 把降级信息**带回来**而不是塞进回调：谁调用谁决定怎么告诉用户（预览是一条
/// 提示条，导出是结果页上的一行），构建器不该猜。
class AudioTrack {
  final String path;

  /// 哪几段配乐没铺上（人话，可直接展示）。为空表示一切正常。
  ///
  /// **预览据此提示、导出据此中止**——同一份信息，两种处置
  final List<String> bgmWarnings;

  const AudioTrack({required this.path, this.bgmWarnings = const []});
}

class AudioTrackBuilder {
  final ProcessRunner run;
  final Directory workDir;

  /// 把一条配乐解析成 ffmpeg 能读的地址。
  ///
  /// 缺省用素材自带的 `previewUrl`——那是**带签名的临时地址，隔天就 403**。
  /// 真实装配要注入 [BgmCache]：优先本地缓存、必要时按 id 现取新地址。
  final Future<String> Function(BgmMaterial material)? resolveBgm;

  AudioTrackBuilder({
    required this.run,
    required this.workDir,
    this.resolveBgm,
  });

  /// 合成整条音轨，返回落地的 WAV 路径。
  ///
  /// [vocalsPath] 是分离出来的纯人声轨；为 null（没装分离工具或分离失败）时，
  /// 被配乐覆盖的段落只能退回原混音——新旧背景会叠在一起，由上层如实告知用户。
  Future<AudioTrack> build({
    required String sourcePath,
    required List<SemanticUnit> units,
    String? vocalsPath,
    BgmPlan bgm = BgmPlan.empty,
    Map<int, String> voiceAudio = const {},

    /// 这是第几条导出变体。配乐每一段可以选多首**备选**，按这个序号轮流取
    /// （见 [BgmSegment.materialFor]）。预览传 null，那时用各段的预览版
    int? variantIndex,

    /// 被**整体替换**的单元：单元下标 → 候选素材的本地路径。
    /// 那一段的口播来自候选自己，不再是原片
    Map<int, String> wholeAudio = const {},

    /// 被整体替换的单元在成片里有多长（单元下标 → 毫秒）。配乐的位置要按
    /// 这个换算，否则从被替换的那个单元之后全部错位
    Map<int, int> wholeDurations = const {},
  }) async {
    workDir.createSync(recursive: true);
    // 整体替换会改变单元时长，后面所有单元跟着挪——配乐的位置必须按
    // **成片**时间轴算（见 [ComposedTimeline]）
    final timeline =
        ComposedTimeline.of(units: units, wholeDurations: wholeDurations);
    final covered = bgmCoveredRanges(units, bgm);
    final degraded = <String>[];

    final parts = <String>[];
    for (final unit in units) {
      parts.addAll(await _unitParts(
        unit: unit,
        sourcePath: sourcePath,
        vocalsPath: vocalsPath,
        covered: covered,
        voiceAudio: voiceAudio,
        wholeAudio: wholeAudio[unit.index],
      ));
    }

    final listFile = File(p.join(workDir.path, 'mix_list.txt'))
      ..writeAsStringSync(ExportCommands.concatList(parts));
    var out = p.join(workDir.path, 'mix_voice.wav');
    await _ffmpeg(
        ExportCommands.concat(listFile: listFile.path, out: out), '拼接声音');

    // 配乐逐段叠上去。段与段之间互不重叠，顺序无所谓。
    //
    // **一段失败只丢那一段，并把原因带回去**：签名地址会过期、网络会断，
    // 而整条音轨作废意味着用户连人声和换过的音色都听不到——真机上就这么
    // 炸过一次，界面只说了句「预览音轨合成失败」，人完全不知道是哪条配乐。
    //
    // 但**只有预览可以这样**：预览时人还在编辑、听得出来。导出拿到
    // [AudioTrack.bgmWarnings] 非空就中止（见 [ExportRunner]）——成片少一段
    // 垫乐是静默的错，交付出去没人会发现。
    for (var i = 0; i < bgm.segments.length; i++) {
      final segment = bgm.segments[i];
      final material = variantIndex == null
          ? segment.previewMaterial
          : segment.materialFor(variantIndex);
      final range =
          timeline.rangeOfUnits(segment.startUnit, segment.endUnit);
      if (range == null) {
        AppLog.warn('配乐「${material.name}」找不到对应的镜头范围，这一段跳过');
        continue;
      }
      final String source;
      try {
        source = await _resolve(material);
      } catch (e) {
        // 底层已经把原因说成人话了，不要再套一层——真机上套出来的那句
        // 「配乐「X」这次取不到（配乐「X」下下来是坏的…）」曲名重复、长得没法读。
        // 但也不能假设它一定带了曲名：没提到就补一次，提到了就原样用
        final raw = e is BgmUnavailableException ? e.message : '$e';
        final name = material.name;
        final message = raw.contains(name) ? raw : '配乐「$name」：$raw';
        AppLog.warn('配乐取不到：$message');
        degraded.add(message);
        continue;
      }
      final mixed = p.join(workDir.path, 'mix_bgm_$i.wav');
      try {
        await _ffmpeg(
          ExportCommands.mixBgm(
            voice: out,
            bgm: source,
            out: mixed,
            startMs: range.$1,
            durationMs: range.$2 - range.$1,
            // 每段自己的音量（见 [BgmSegment.volume]）——预览和导出走同一条路，
            // 这里改了两边一起变
            bgmVolume: segment.volume,
          ),
          '配乐「${material.name}」',
        );
      } catch (e) {
        final message = '配乐「${material.name}」这一段没铺上：$e';
        AppLog.warn(message);
        degraded.add(message);
        continue;
      }
      out = mixed;
    }
    return AudioTrack(path: out, bgmWarnings: List.unmodifiable(degraded));
  }

  /// 缺省退回素材自带地址——它随时可能已经失效，所以真实装配一定要注入
  /// [resolveBgm]
  Future<String> _resolve(BgmMaterial material) async {
    final resolver = resolveBgm;
    if (resolver != null) return resolver(material);
    final url = material.previewUrl;
    if (url == null || url.isEmpty) {
      throw StateError('没有可用地址');
    }
    return url;
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

    /// 这个单元被整体替换了：口播来自这条候选素材，整段取用不裁不补
    String? wholeAudio,
  }) async {
    // 整体替换优先于换音色——同一个单元两者都设时导出前置检查已经拦下了
    if (wholeAudio != null && File(wholeAudio).existsSync()) {
      final out = p.join(workDir.path, 'mix_u${unit.index}_whole.wav');
      await _ffmpeg(
        ExportCommands.wholeReplacementAudio(input: wholeAudio, out: out),
        'U${unit.index + 1} 的替换声音',
      );
      return [out];
    }

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

  /// 配乐覆盖到的时间区间（按台词语义单元换算）
  static List<(int, int)> bgmCoveredRanges(
          List<SemanticUnit> units, BgmPlan bgm) =>
      [
        for (final segment in bgm.segments) ?BgmPlan.unitRangeOf(units, segment),
      ];

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
