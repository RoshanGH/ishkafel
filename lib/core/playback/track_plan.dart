import 'package:flutter/foundation.dart';

/// 一条轨上的一段：**成片时间轴上的 [atMs, atMs+durationMs)** 这段时间，
/// 播 [source] 这个文件的 [inMs] 开始处。
///
/// 段与段之间在同一条轨上不重叠、按 [atMs] 升序。
@immutable
class TrackSegment {
  /// 在成片时间轴上从什么时候开始
  final int atMs;

  /// 在成片时间轴上占多长
  final int durationMs;

  /// 播哪个文件
  final String source;

  /// 从这个文件的什么位置开始播
  final int inMs;

  /// 这一段在**原片时间轴**上对应哪一段（起点，时长）。
  ///
  /// 时间线画的是原片切分，播放头要靠它换算回去。绝大多数段落就是自己
  /// （播的就是原片那一段），只有**整体替换**不同：播的是另一条素材，
  /// 原片时刻在那儿根本不存在，但时间线上那个格子还是按原单元的长度画的。
  final int sourceStartMs;
  final int sourceSpanMs;

  const TrackSegment({
    required this.atMs,
    required this.durationMs,
    required this.source,
    this.inMs = 0,
    int? sourceStartMs,
    int? sourceSpanMs,
  })  : sourceStartMs = sourceStartMs ?? inMs,
        sourceSpanMs = sourceSpanMs ?? durationMs;

  int get endMs => atMs + durationMs;

  bool covers(int ms) => ms >= atMs && ms < endMs;

  /// 成片时刻 [ms] 对应原片的哪一刻。
  ///
  /// **整体替换段按比例映射**：候选 11.3 秒顶掉原来的 15.1 秒，1:1 映射会让
  /// 播放头走到格子的 3/4 处就到头，下一拍直接跳到下一个单元——用户看到的
  /// 是「还剩 1/5 就跳过去了」。按比例走才能匀速走完整个格子，而且语义上也
  /// 对：那一段播的是别的素材，本来就没有一一对应的原片时刻。
  int sourceMsAt(int ms) {
    final into = ms - atMs;
    if (sourceSpanMs == durationMs || durationMs <= 0) {
      return sourceStartMs + into;
    }
    return sourceStartMs + (into * sourceSpanMs / durationMs).round();
  }

  @override
  bool operator ==(Object other) =>
      other is TrackSegment &&
      other.atMs == atMs &&
      other.durationMs == durationMs &&
      other.source == source &&
      other.inMs == inMs &&
      other.sourceStartMs == sourceStartMs &&
      other.sourceSpanMs == sourceSpanMs;

  @override
  int get hashCode =>
      Object.hash(atMs, durationMs, source, inMs, sourceStartMs, sourceSpanMs);

  @override
  String toString() => 'TrackSegment($atMs+$durationMs ← $source@$inMs)';
}

/// 配乐段落多带音量与曲子本身的长度——每段音量独立（见 [BgmSegment.volume]）；
/// 曲长用来算「不够长就循环」时该从曲子的哪一刻接上
@immutable
class BgmTrackSegment {
  final TrackSegment clip;
  final double volume;

  /// 这首曲子本身有多长。为 0 表示不知道，那就不循环、播完即止
  final int sourceDurationMs;

  const BgmTrackSegment({
    required this.clip,
    required this.volume,
    this.sourceDurationMs = 0,
  });

  /// 成片时刻 [ms] 该播这首曲子的哪一刻。曲子比这一段短就绕回开头
  /// （「时长不够就循环」——产品定的配乐原则）
  int sourceMsAt(int ms) {
    final offset = ms - clip.atMs;
    if (sourceDurationMs <= 0) return offset;
    return offset % sourceDurationMs;
  }

  @override
  bool operator ==(Object other) =>
      other is BgmTrackSegment &&
      other.clip == clip &&
      other.volume == volume &&
      other.sourceDurationMs == sourceDurationMs;

  @override
  int get hashCode => Object.hash(clip, volume, sourceDurationMs);
}

/// 预览要播的东西——**三条各自独立的轨**，谁到点了谁播自己那一段。
///
/// **为什么不再预合成**：此前预览是先用 ffmpeg 把 43 段拼成一整条新片子再喂
/// 给播放器，一轮几分钟、几百兆磁盘，而其中 42 段是把原片原封不动切了一遍。
/// 用户原话：「它就不能像剪映一样各是各的吗？播放的时候一起播放。」——能，
/// 而且实测可行：libmpv 的 `edl://` 能把「原片一段 + 候选一段」当成一个虚拟
/// 文件直接播（零转码），多个播放器实例同时跑的偏差在 ±70ms 以内且不累积。
///
/// 原片的背景音**刻意不单独成轨**：人声分离是有损的（实测残差 −27dB，
/// 听得出来）。没铺配乐的段落直接用原混音、一个字节不改，只有被配乐盖住的
/// 段落才换成纯人声——否则全片都要先损一道。
@immutable
class TrackPlan {
  /// 画面：没替换的用原片、整体替换用候选整条、镜头替换用变速对齐后的切片
  final List<TrackSegment> video;

  /// 口播：换过音色用配音、整体替换用候选自己的声音、被配乐盖住用纯人声、
  /// 其余用原混音
  final List<TrackSegment> voice;

  /// 配乐：各段各的曲子与音量
  final List<BgmTrackSegment> bgm;

  /// 哪几段配乐这一次没铺上（人话，可直接展示）。
  /// 预览可以少一段垫乐——人还在编辑、听得出来——但必须说出来
  final List<String> bgmMissing;

  /// 空白任务里还没挑素材、这一轮预览**跳过**了的分子（下标，从 0 起）。
  ///
  /// 没有原片可以垫底，跳过是唯一的选择——但跳过必须说出来，否则用户看到
  /// 的片子比他排的短一段，还以为是自己记错了
  final List<int> skippedEmptyUnits;

  const TrackPlan({
    this.video = const [],
    this.voice = const [],
    this.bgm = const [],
    this.bgmMissing = const [],
    this.skippedEmptyUnits = const [],
  });

  static const empty = TrackPlan();

  bool get isEmpty => video.isEmpty && voice.isEmpty && bgm.isEmpty;

  /// 成片总长（按画面轨算——它才是片子的长度）
  int get totalMs => video.isEmpty ? 0 : video.last.endMs;

  /// 成片时刻 → 原片时刻。**换方案时要靠它记住「我停在哪儿」**：
  /// 直接记成片毫秒的话，新方案的总长一变，同一个毫秒对应的内容就完全不是
  /// 同一处了——用户点一下 ★ 就被扔到片子的别处。
  int toSourceMs(int composedMs) {
    for (final segment in video) {
      if (segment.covers(composedMs)) return segment.sourceMsAt(composedMs);
    }
    return video.isEmpty ? composedMs : video.last.sourceMsAt(video.last.endMs - 1);
  }

  /// 原片时刻 → 这一套轨上的成片时刻（[toSourceMs] 的逆）。
  ///
  /// 落不进任何一段时**取最近的那一段的边界**，而不是一律甩到片尾。这条
  /// 兜底以前写的是「非 0 即 totalMs」，一旦哪条轨在原片轴上留了空洞
  /// （见 [TrackPlanBuilder] 里变速切片那段的说明），用户正看着的位置就会
  /// 被一脚踢到片子结尾——那是最糟的一种失败方式：看上去像播放器发疯。
  int toComposedMs(int sourceMs) {
    var bestMs = 0;
    var bestGap = -1;
    for (final segment in video) {
      final from = segment.sourceStartMs;
      final to = from + segment.sourceSpanMs;
      if (sourceMs >= from && sourceMs < to) {
        if (segment.sourceSpanMs <= 0) return segment.atMs;
        final into = sourceMs - from;
        return segment.atMs +
            (into * segment.durationMs / segment.sourceSpanMs).round();
      }
      // 离得多远：在这一段之前就是 from-sourceMs，之后就是 sourceMs-(to-1)
      final gap = sourceMs < from ? from - sourceMs : sourceMs - to + 1;
      if (bestGap < 0 || gap < bestGap) {
        bestGap = gap;
        bestMs = sourceMs < from ? segment.atMs : segment.endMs;
      }
    }
    return bestMs.clamp(0, totalMs);
  }

  /// [ms] 时刻该播哪一段配乐；没有就返回 null
  BgmTrackSegment? bgmAt(int ms) {
    for (final segment in bgm) {
      if (segment.clip.covers(ms)) return segment;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is TrackPlan &&
      listEquals(other.video, video) &&
      listEquals(other.voice, voice) &&
      listEquals(other.bgm, bgm) &&
      listEquals(other.bgmMissing, bgmMissing);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(video), Object.hashAll(voice),
          Object.hashAll(bgm));
}
