import '../audio/audio_track_builder.dart';
import '../audio/bgm_plan.dart';
import '../ffmpeg/proxy_spec.dart';
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
    /// 画面轨读的原片。**预览走代理**（见 [ProxySpec]）：段与段规格一致，
    /// 播放器在接缝处才不用重建解码器。代理还没生成好时传原片路径，
    /// 那一轮先按原样播
    /// 画面轨读的原片。**为 null 表示空白任务**——那时没挑素材的分子
    /// 没有任何东西可播，只能跳过（记进 [TrackPlan.skippedEmptyUnits]）
    required String? sourcePath,

    /// 口播轨读的原片。**始终是原片本身，不走代理**：音频解码不吃硬件，
    /// 而代理是 `-c:a copy` 出来的、音质本就一样，没有理由多绕一层。
    /// 为 null 时与 [sourcePath] 相同（没有代理的场景）
    String? audioSourcePath,
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    required Map<int, LocalMaterial> materials,
    Map<String, String> speedFitted = const {},

    /// 还没挑素材的那几段垫的黑场（单元下标 → 本地文件）。
    ///
    /// **必须垫**：预览走 mpv 的 edl://，而 EDL 没有「空档」——留洞会被压掉，
    /// 从那儿起后面所有内容都提前一截，时间线和播放器就此对不上
    /// （2026-09-08 真机：时间线画到 01:47，播放器只走到 01:37）。
    /// 没垫上时照旧留洞：位置会错，但至少还能播，且 Edl 会打警告
    Map<int, String> gapClips = const {},
    String? vocalsPath,
    Map<String, String> voiceAudio = const {},
    BgmPlan bgm = BgmPlan.empty,

    /// 配乐在本地的文件（曲子 id → 路径）。取不到的那一段直接不铺，
    /// 并记进 [TrackPlan.bgmMissing]——预览可以少一段垫乐，但必须说出来
    Map<int, String> bgmPaths = const {},

    /// 替换素材已经分离好的纯人声（素材路径 → 人声轨路径）。
    ///
    /// 整体替换的段落铺了配乐时用它——素材自带的背景音留着的话，它和新配乐
    /// 就是两首曲子一起响。**预览与导出走同一条规则**：听到的就是要交付的。
    /// 取不到就用素材原声，那时配乐会叠，由界面如实提示
    Map<String, String> materialVocals = const {},
  }) {

    final video = <TrackSegment>[];
    final voice = <TrackSegment>[];
    final skipped = <int>[];
    /// 放不了的那几段在成片上的区间——播放头走到这儿要停下来点名
    final unplayable = <UnplayableSpan>[];
    // 成片时间轴上的游标：整体替换会改变段落长度，后面的全跟着挪
    var at = 0;
    // 单元下标 → 它在成片上占的 [起, 止)，配乐要按它定位
    final unitRanges = <int, (int, int)>{};

    // 被配乐盖住的是**哪几格**（列表下标）。见 track_plan_builder 里那段说明
    final coveredUnits = AudioTrackBuilder.bgmCoveredUnits(units, bgm);
    for (var u = 0; u < units.length; u++) {
      final unit = units[u];
      final start = at;
      final replacement = _replacementOf(replacements, unit.index);
      final whole = _wholePick(replacement, materials);

      if (whole != null) {
        // 整体替换：画面与声音都来自候选，整段原样接上，时长跟候选走
        final durationMs = whole.durationMs ?? unit.durationMs;
        video.add(TrackSegment(
          atMs: at,
          durationMs: durationMs,
          source: whole.path,
          // 画面轨不出声：这条线的声音一律走口播轨（整体替换用候选自己的
          // 声音、被配乐盖住用纯人声）。两边都响就是两份声音重叠
          volume: 0,
          // 时间线上这个格子还是按原单元画的，播放头要按比例走完它
          sourceStartMs: unit.startMs,
          sourceSpanMs: unit.durationMs,
        ));
        // 这一段被配乐盖住时用素材的纯人声（与导出同一条规则）
        final wholeCovered = coveredUnits.contains(u);
        final wholeVoice =
            (wholeCovered ? materialVocals[whole.path] : null) ?? whole.path;
        voice.add(TrackSegment(
            atMs: at, durationMs: durationMs, source: wholeVoice));
        at += durationMs;
        unitRanges[unit.index] = (start, at);
        continue;
      }

      // 没挑素材、又没有原片可垫的单元：跳过并如实记下来。
      //
      // 两种情况都在这儿：空白任务里的分子（整条任务没有原片），以及
      // **手加的台词语义单元**（这条任务有原片，但原片里没有它）。
      //
      // 判据必须是「**这个单元**有没有原片来源」，不是「这条任务有没有原片」
      // ——同一条任务里两种单元现在是并存的。按后者判的话，手加单元会掉进
      // 下面「按镜头逐段取原片」的分支，而它的 startMs/endMs 只是时间线上的
      // 占位、落在原片时长之外：取的是一段根本不存在的时间，播出来是黑的
      // 或者干脆卡住（2026-09-08 真机：「添加的台词语义单元不能正常播放」）。
      if (sourcePath == null || !unit.hasSource) {
        skipped.add(unit.index);
        // **跳过的是画面，不是时间**：这一段照样占着它在成片里的位置，
        // 游标必须往前走，否则后面的单元全部前移——真机上用户把手加的单元
        // 拖到最前，一按播放直接从 U2 开始，时间线画到 01:46 而播放器只到
        // 01:36，他以为软件把他加的那一段吃了（2026-09-08）
        at += unit.durationMs;
        unitRanges[unit.index] = (start, at);
        unplayable.add(UnplayableSpan(
            unitIndex: unit.index, startMs: start, endMs: at));
        // 垫上黑场，让这一段在 EDL 里真的占着时间。人一播到这儿仍然会
        // 停下来点名（见 unplayable），不会对着黑屏猜
        if (gapClips[unit.index] case final gap?) {
          video.add(TrackSegment(
              atMs: start,
              durationMs: unit.durationMs,
              source: gap,
              volume: 0,
              sourceStartMs: unit.startMs,
              sourceSpanMs: unit.durationMs));
          voice.add(TrackSegment(
              atMs: start, durationMs: unit.durationMs, source: gap));
        }
        continue;
      }

      // 走到这儿 sourcePath 一定非空——上一个分支已经把没有原片的都拦下了
      final audioSource = audioSourcePath ?? sourcePath;

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
            ? TrackSegment(
                atMs: at,
                durationMs: slotMs,
                source: fitted,
                volume: 0, // 画面轨不出声，声音走口播轨
                // 它在**原片轴**上占的还是这个镜头的坑位。不写这两项的话
                // sourceStartMs 会默认取 inMs（=0），这一段就变成「对应原片
                // 开头几秒」，同时把它真正占着的原片区间挖成一个空洞——换轨
                // 那一刻按逻辑位置回原处会谁都不命中，一路兜到片尾
                sourceStartMs: shotStart,
                sourceSpanMs: slotMs,
              )
            : TrackSegment(
                atMs: at,
                durationMs: slotMs,
                source: sourcePath,
                volume: 0, // 画面轨不出声，声音走口播轨
                inMs: shotStart));
        at += slotMs;
      }

      // 声音：换过音色的整段用配音，否则按镜头取原混音/纯人声
      // 按单元的**身份**取：按位置取的话，人挪过顺序之后念的是别人那段
      final generated = voiceAudio[unit.uid];
      if (generated != null) {
        voice.add(TrackSegment(
            atMs: start, durationMs: at - start, source: generated));
      } else {
        var cursor = start;
        for (final (shotStart, shotEnd, _) in shots) {
          final slotMs = shotEnd - shotStart;
          // 被配乐盖住的段落必须用纯人声，否则新配乐与原背景两首曲子一起响
          final clean = vocalsPath != null &&
              coveredUnits.contains(u);
          voice.add(TrackSegment(
            atMs: cursor,
            durationMs: slotMs,
            source: clean ? vocalsPath : audioSource,
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
      skippedEmptyUnits: List.unmodifiable(skipped),
      unitRanges: Map.unmodifiable(unitRanges),
      unplayable: List.unmodifiable(unplayable),
      composedTotalMs: at,
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

  /// 这一格被配乐盖住了没有。**按列表下标问**——原来是拿原片时间区间比重叠，
  /// 而那个区间是用列表下标去取 startMs/endMs 拼的：调过序就指到别的段上，
  /// 甚至首尾颠倒。判错的后果是这一段该用纯人声还是原声反了，
  /// 人一听就知道不对（2026-09-08 真机：调完顺序背景音乐变了）

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
          last.inMs + last.durationMs == segment.inMs &&
          // 时长被替换改过的段不能并进来——它的播放头映射是按比例的
          last.sourceSpanMs == last.durationMs &&
          segment.sourceSpanMs == segment.durationMs) {
        out[out.length - 1] = TrackSegment(
          atMs: last.atMs,
          durationMs: last.durationMs + segment.durationMs,
          source: last.source,
          inMs: last.inMs,
          // 原片坐标显式带上：靠 inMs 兜底只对「播的就是原片」的段成立，
          // 而这个判断不该埋在默认值里
          sourceStartMs: last.sourceStartMs,
          sourceSpanMs: last.durationMs + segment.durationMs,
        );
        continue;
      }
      out.add(segment);
    }
    return out;
  }
}
