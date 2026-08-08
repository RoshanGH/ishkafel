import '../audio/audio_track_builder.dart';
import '../audio/bgm_plan.dart';
import '../models/semantic_unit.dart';
import '../replacement/replacement_plan.dart';
import 'track_plan.dart';

/// 一条候选素材在本地的样子：路径 + 真实时长。
///
/// 时长探不出来时为 null——那时整体替换只能按原坑位长度算，宁可这样也不能
/// 拿 0 冒充（后面所有段落会挤成一团）。
class LocalMaterial {
  final String path;
  final int? durationMs;

  const LocalMaterial({required this.path, this.durationMs});
}

/// 把「替换方案」翻译成「三条轨各自播什么」。
///
/// 纯函数，不碰磁盘也不碰播放器——这套「谁在什么时候播哪个文件的哪一段」的
/// 规则是产品的核心，必须能脱离 UI 与 ffmpeg 单测。
class TrackPlanBuilder {
  /// [materials] 是**已经固定到本地**的候选（候选 id → 本地文件）。取不到的
  /// 候选一律当没选——预览宁可播原片，也不能播一个空洞。
  ///
  /// [speedFitted] 是镜头替换那几段**预先变速对齐好**的切片（镜头 key →
  /// 本地文件）。只有标了 ★ 的那条需要，其余候选到导出时才变速。
  static TrackPlan build({
    required String sourcePath,
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    required Map<int, LocalMaterial> materials,
    Map<String, String> speedFitted = const {},
    String? vocalsPath,
    Map<int, String> voiceAudio = const {},
    BgmPlan bgm = BgmPlan.empty,

    /// 配乐在本地的文件（曲子 id → 路径）。取不到的那一段直接不铺，
    /// 并记进 [TrackPlan.bgmMissing]——预览可以少一段垫乐，但必须说出来
    Map<int, String> bgmPaths = const {},
  }) {
    final video = <TrackSegment>[];
    final voice = <TrackSegment>[];
    // 成片时间轴上的游标：整体替换会改变段落长度，后面的全跟着挪
    var at = 0;
    // 单元下标 → 它在成片上占的 [起, 止)，配乐要按它定位
    final unitRanges = <int, (int, int)>{};

    for (final unit in units) {
      final start = at;
      final replacement = _replacementOf(replacements, unit.index);
      final whole = _wholePick(replacement, materials);

      if (whole != null) {
        // 整体替换：画面与声音都来自候选，整段原样接上，时长跟候选走
        final durationMs = whole.durationMs ?? unit.durationMs;
        video.add(TrackSegment(
            atMs: at, durationMs: durationMs, source: whole.path));
        voice.add(TrackSegment(
            atMs: at, durationMs: durationMs, source: whole.path));
        at += durationMs;
        unitRanges[unit.index] = (start, at);
        continue;
      }

      // 没有整体替换：画面按镜头逐段取，声音按「这一段该用哪条音源」取
      final shots = unit.shots.isEmpty
          ? [(unit.startMs, unit.endMs, -1)]
          : [
              for (var i = 0; i < unit.shots.length; i++)
                (unit.shots[i].startMs, unit.shots[i].endMs, i),
            ];
      for (final (shotStart, shotEnd, shotIndex) in shots) {
        final slotMs = shotEnd - shotStart;
        final fitted = shotIndex < 0
            ? null
            : speedFitted[shotKey(unit.index, shotIndex)];
        video.add(fitted != null
            // 变速切片已经是坑位那么长了，从头播就行
            ? TrackSegment(atMs: at, durationMs: slotMs, source: fitted)
            : TrackSegment(
                atMs: at,
                durationMs: slotMs,
                source: sourcePath,
                inMs: shotStart));
        at += slotMs;
      }

      // 声音：换过音色的整段用配音，否则按镜头取原混音/纯人声
      final generated = voiceAudio[unit.index];
      if (generated != null) {
        voice.add(TrackSegment(
            atMs: start, durationMs: at - start, source: generated));
      } else {
        var cursor = start;
        for (final (shotStart, shotEnd, _) in shots) {
          final slotMs = shotEnd - shotStart;
          // 被配乐盖住的段落必须用纯人声，否则新配乐与原背景两首曲子一起响
          final clean = vocalsPath != null &&
              _coveredByBgm(units, bgm, shotStart, shotEnd);
          voice.add(TrackSegment(
            atMs: cursor,
            durationMs: slotMs,
            source: clean ? vocalsPath : sourcePath,
            inMs: shotStart,
          ));
          cursor += slotMs;
        }
      }
      unitRanges[unit.index] = (start, at);
    }

    final missing = <String>[];
    return TrackPlan(
      // 画面也要合并：一个单元二十个镜头、全取自原片同一段连续区间时，
      // 写二十条等于二十次 seek，切换点会有可见的顿挫
      video: List.unmodifiable(_merged(video)),
      voice: List.unmodifiable(_merged(voice)),
      bgm: List.unmodifiable(
          _bgmTrack(bgm, unitRanges, bgmPaths, missing)),
      bgmMissing: List.unmodifiable(missing),
    );
  }

  /// 镜头替换的变速切片按这个 key 索引
  static String shotKey(int unitIndex, int shotIndex) => '$unitIndex/$shotIndex';

  static UnitReplacement _replacementOf(
      List<UnitReplacement> replacements, int index) {
    if (index < 0 || index >= replacements.length) {
      return UnitReplacement.keepOriginal();
    }
    return replacements[index];
  }

  /// 这个单元的整体替换预览版；没选、或素材还没落到本地就返回 null
  static LocalMaterial? _wholePick(
      UnitReplacement replacement, Map<int, LocalMaterial> materials) {
    if (replacement.mode != ReplacementMode.whole) return null;
    final id = replacement.wholePreviewId;
    return id == null ? null : materials[id];
  }

  static bool _coveredByBgm(
      List<SemanticUnit> units, BgmPlan bgm, int startMs, int endMs) {
    for (final (a, b) in AudioTrackBuilder.bgmCoveredRanges(units, bgm)) {
      if (startMs < b && endMs > a) return true;
    }
    return false;
  }

  /// 配乐落在成片时间轴的哪一段。
  ///
  /// 一段配乐铺在若干个**台词语义单元**上，而整体替换会改变单元长度——
  /// 所以位置要按上面算出来的成片范围取，不能拿原片毫秒。
  static List<BgmTrackSegment> _bgmTrack(
    BgmPlan bgm,
    Map<int, (int, int)> unitRanges,
    Map<int, String> bgmPaths,
    List<String> missing,
  ) {
    final out = <BgmTrackSegment>[];
    for (final segment in bgm.segments) {
      final from = unitRanges[segment.startUnit];
      final to = unitRanges[segment.endUnit];
      if (from == null || to == null) continue;
      final material = segment.previewMaterial;
      final path = bgmPaths[material.id];
      if (path == null) {
        // 少一段垫乐可以接受（人还在编辑，听得出来），但绝不能不吭声
        missing.add('配乐「${material.name}」还没存到本地，这一段暂时没有垫乐');
        continue;
      }
      out.add(BgmTrackSegment(
        clip: TrackSegment(
          atMs: from.$1,
          durationMs: to.$2 - from.$1,
          // 曲子从头播；不够长就循环、太长就播到段尾停（由播放层处理）
          source: path,
        ),
        volume: segment.volume,
        sourceDurationMs: material.durationMs,
      ));
    }
    out.sort((a, b) => a.clip.atMs.compareTo(b.clip.atMs));
    return out;
  }

  /// 把相邻且首尾相接、来自同一个源的段落并成一段。
  ///
  /// 一个单元切成二十个镜头、声音全取自原片的同一段连续区间时，EDL 里写
  /// 二十条和写一条播出来完全一样——但二十条意味着二十次 seek，切换点会有
  /// 可闻的接缝。
  static List<TrackSegment> _merged(List<TrackSegment> segments) {
    final out = <TrackSegment>[];
    for (final segment in segments) {
      final last = out.isEmpty ? null : out.last;
      if (last != null &&
          last.source == segment.source &&
          last.endMs == segment.atMs &&
          last.inMs + last.durationMs == segment.inMs) {
        out[out.length - 1] = TrackSegment(
          atMs: last.atMs,
          durationMs: last.durationMs + segment.durationMs,
          source: last.source,
          inMs: last.inMs,
        );
        continue;
      }
      out.add(segment);
    }
    return out;
  }
}
