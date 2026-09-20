import '../core/analysis/providers.dart' show AsrSentence;
import '../core/editing/frame_time.dart';
import '../core/export/composed_timeline.dart';
import '../core/models/renew_task.dart';
import '../core/models/semantic_unit.dart';
import '../core/models/shot.dart';
import '../core/replacement/replacement_plan.dart';
import '../core/replacement/unit_base.dart';
import '../core/subtitle/heard_words.dart';
import '../core/subtitle/slot_subtitles.dart';
import '../core/subtitle/subtitle_overlay.dart';
import '../core/subtitle/subtitle_problems.dart';
import '../core/subtitle/subtitle_track.dart';
import '../core/subtitle/voice_source.dart';
import '../core/timeline/composed_frames.dart';
import 'task_view.dart' show wholeDurationsOf;

/// 字幕的两份报告——给 Agent 看，不给结论（spec §5）。
///
/// 三条规矩，字段都从它们推出来：
/// 1. **对外只出帧，不出毫秒**：毫秒退回存储格式，两套数字并存就一定有人
///    对错。
/// 2. **位置一律是成片帧轴上的绝对帧**：字幕存的是「相对这一镜开头」，
///    这里按 `frames.frameAt(单元成片起点 + 镜头在单元内的偏移 + 行内偏移)`
///    换算成绝对帧再报出去。
/// 3. **「听到什么」和「显示什么」分成两块字段，永不混写**：`heard` 是耳朵
///    听到的（[heardInShot]），`lines` 是要烧的字（[subtitleLinesForSlot]）
///    ——两者对不上正是这个模块要抓的那类问题（见 [subtitleProblemsOf]）。
///
/// 这一批的 `by` 只分 `auto` / `edited`：`SubtitleTrack` 现在只记「改没改过」
/// （`linesOf(slot) == null` 是没改过），记不清谁改的——那要等第二批给它加
/// `EditStamp`。宁可报 `edited`，不猜一个 `human`。

/// 一次性把「这一镜要问的四步」跑完：[voiceSourceOf] → [heardInShot] →
/// [subtitleLinesForSlot] → [subtitleProblemsOf]。
///
/// **`source` 只从 [voiceSourceOf] 来，这里不自己拼**：[heardInShot] 不会
/// 校验传进去的 `source` 跟 `unit` 吻不吻合，传错的话 `spillsInto` 会被
/// 静默抑制且没有任何提示——这一处调用集中在一个函数里，就是为了不给
/// 「自己拼一个 source」留机会。
class _ShotFacts {
  final SemanticUnit unit;
  final Shot shot;
  final ({VoiceSource source, String note}) voice;
  final Heard heard;
  final List<SubtitleLine> lines;
  final List<SubtitleProblem> problems;

  /// 这一镜在成片帧轴上的精确位置。**null 不等于「这一镜不存在」**，
  /// 只是给不了精确帧位置——见 [_factsOf] 上方那段注释
  final FrameSpan? span;
  final String by;

  const _ShotFacts({
    required this.unit,
    required this.shot,
    required this.voice,
    required this.heard,
    required this.lines,
    required this.problems,
    required this.span,
    required this.by,
  });
}

// 这一镜出不出现在报告里，只看它在不在 unit.shots 里；shotSpan 是不是 null
// 只决定有没有精确帧位置，两件事不能混为一谈。
//
// 整体替换把这一段整个换成了另一条素材，原片的镜头切分在成片里确实不存在
// 了——但那一镜在 unit.shots 里是有的，voiceSourceOf 会把它报成 replaced，
// heardInShot 也专门为这一档写了不依赖 shotSpan 的分支（直接给空文本+理由，
// 不用等 shotSpan 判断）。原来这里按 span 是不是 null 去筛掉整行，Agent
// 看到的是「这段镜头凭空消失」，连它存在过都不知道——比把几种「没台词」
// 混成一种还糟：那好歹这一行还在，这里是整行没了。
//
// 设计文档「整体替换段不给词级」那条，说的是不给逐字位置（词级），
// 不是不给这一行。
/// 算出第 [unitIndex]/[shotIndex] 镜的四步事实：[voiceSourceOf] →
/// [heardInShot] → [subtitleLinesForSlot] → [subtitleProblemsOf]。
/// `span` 为 null 时照样把四步走完——后两步本来就支持可空的 `shotSpan`。
_ShotFacts _factsOf({
  required ComposedFrames frames,
  required ComposedTimeline timeline,
  required List<SemanticUnit> units,
  required List<UnitReplacement> replacements,
  required SubtitleTrack track,
  required List<AsrSentence> originalSentences,
  required int unitIndex,
  required int shotIndex,
}) {
  final unit = units[unitIndex];
  final shot = unit.shots[shotIndex];
  final replacement = unitIndex < replacements.length
      ? replacements[unitIndex]
      : UnitReplacement.keepOriginal();
  final voice = voiceSourceOf(unit: unit, replacement: replacement);
  final heard = heardInShot(
    frames: frames,
    units: units,
    unitIndex: unitIndex,
    shotIndex: shotIndex,
    source: voice.source,
    originalSentences: originalSentences,
  );
  final lines = subtitleLinesForSlot(
    track: track,
    sentences: originalSentences,
    unitUid: unit.uid,
    shotIndex: shotIndex,
    slotStartMs: shot.startMs,
    slotEndMs: shot.endMs,
    // 底片是不是一条挑来的素材，只认这一条判据——跟 voiceSourceOf 内部
    // 判「base」用的是同一个函数，两边不会走岔
    onMaterialBase: hasOwnBaseShots(unit),
    baseSentences: unit.baseSentences,
    baseSlotStartMs: shot.startMs - unit.startMs,
    baseSlotEndMs: shot.endMs - unit.startMs,
  );
  final span = frames.shotSpan(unitIndex, shotIndex);
  final problems = subtitleProblemsOf(
    shotSpan: span,
    heard: heard,
    lines: lines,
    slotDurationMs: shot.endMs - shot.startMs,
  );
  final slot = SubtitleSlot(unitUid: unit.uid, shotIndex: shotIndex);
  final by = track.linesOf(slot) == null ? 'auto' : 'edited';
  return _ShotFacts(
    unit: unit,
    shot: shot,
    voice: voice,
    heard: heard,
    lines: lines,
    problems: problems,
    span: span,
    by: by,
  );
}

/// 这一镜的「地址」，人和 Agent 都按这个格式说话
String _at(int unitIndex, int shotIndex) =>
    'U${unitIndex + 1}S${shotIndex + 1}';

/// 全片有哪些镜头——`unit.shots` 里有的都算，**不按 `shotSpan` 筛**
/// （见 [_factsOf] 上方那段注释：有没有精确帧位置，跟这一镜在不在报告里
/// 是两件事）。
List<({int unit, int shot})> _allShots(List<SemanticUnit> units) => [
      for (var u = 0; u < units.length; u++)
        for (var s = 0; s < units[u].shots.length; s++) (unit: u, shot: s),
    ];

/// 建一次全片都要用到的上下文，全片报告和单镜报告共用，
/// 不许各自再拼一份——那正是这个模块要堵住的洞。
///
/// [wholeDurations] 由调用方传入（算法只有 [wholeDurationsOf] 这一处，
/// 见 `task_view.dart`）——调用方要先看一眼 `unknown` 是否为空，
/// 那关系到整份报告要不要整块拒答（见 [subtitleReport] / [_framesUnavailableNote]）。
({
  List<SemanticUnit> units,
  List<UnitReplacement> replacements,
  ComposedTimeline timeline,
  ComposedFrames frames,
  SubtitleTrack track,
  List<AsrSentence> sentences,
}) _contextOf(RenewTask task, Map<int, int> wholeDurations) {
  final units = task.units ?? const <SemanticUnit>[];
  final replacements = task.replacementsFor(units);
  final timeline =
      ComposedTimeline.of(units: units, wholeDurations: wholeDurations);
  final frames = ComposedFrames.of(
    timeline: timeline,
    fps: task.videoInfo?.fpsExact,
  );
  return (
    units: units,
    replacements: replacements,
    timeline: timeline,
    frames: frames,
    track: task.subtitleTrack,
    sentences: task.asrSentences ?? const <AsrSentence>[],
  );
}

/// 算不准就整块不报并点名——跟 `task_view.dart` 的 `composedUnavailable`
/// 是同一条判据、同一句文案。
///
/// 整体替换选了候选、但那条候选的时长还没探出来时，[ComposedTimeline]
/// 会静默退回原片那个坑位的长度（它自己管不了「这个数以后会变」这件事，
/// 只能就着手头的数字往下算）。后果不止于那一个单元：**它之后每一段在
/// 成片里的起点都跟着错**，于是整份报告里的帧号全部不作数，而且会在
/// `candidates fetch` 探出真时长之后整体平移。报出去的帧号看起来精确、
/// 实际不作数，正是这份设计要防的「不编假数字」——宁可不报，也不给一份
/// 会变的坐标。
///
/// 跟「下标越界」分得开：那是 null，这是一份带 `framesUnavailable` 的 map，
/// 两件事不能共用一个返回值，否则调用方分不清「问错了」还是「算不出来」。
String _framesUnavailableNote(List<int> unknown) =>
    '这几个单元是整体替换，但还不知道选中素材有多长，'
    '所以整条片子的成片位置都算不准，字幕的帧号也就无从谈起：'
    '${unknown.map((i) => 'U${i + 1}').join('、')}。'
    '先把素材下下来（candidates fetch），再来看字幕';

/// 全片那份——`subtitle show <任务>`。一镜一行，扫得动。
Map<String, dynamic> subtitleReport(RenewTask task) {
  final whole = wholeDurationsOf(task);
  if (whole.unknown.isNotEmpty) {
    return {'framesUnavailable': _framesUnavailableNote(whole.unknown)};
  }
  final ctx = _contextOf(task, whole.durations);

  final shots = [
    for (final pos in _allShots(ctx.units))
      _shotRow(_factsOf(
        frames: ctx.frames,
        timeline: ctx.timeline,
        units: ctx.units,
        replacements: ctx.replacements,
        track: ctx.track,
        originalSentences: ctx.sentences,
        unitIndex: pos.unit,
        shotIndex: pos.shot,
      ), pos.unit, pos.shot, ctx.frames),
  ];

  return {
    'projectFps': ctx.frames.fps.toString(),
    'fpsSource': ctx.frames.fpsSource,
    'totalFrames': ctx.frames.totalFrames,
    'shots': shots,
  };
}

Map<String, dynamic> _shotRow(
  _ShotFacts f,
  int unitIndex,
  int shotIndex,
  ComposedFrames frames,
) {
  final span = f.span;
  return {
    'at': _at(unitIndex, shotIndex),
    'unitUid': f.unit.uid,
    'unit': unitIndex,
    'shot': shotIndex,
    // 给不了精确帧位置（整体替换的一整块）就整个键不出现，不编一个
    if (span != null) 'frames': [span.first, span.last],
    if (span != null) 'tc': '${frames.tc(span.first)} → ${frames.tc(span.last)}',
    'voice': f.voice.source.name,
    'heard': f.heard.text,
    'lines': [for (final l in f.lines) l.text],
    'by': f.by,
    if (f.problems.isNotEmpty)
      'problems': [for (final p in f.problems) p.kind],
  };
}

/// 单镜那份——`subtitle show <任务> --unit 1 --shot 2`。
///
/// 下标越界一律返回 null，不抛。**落在整体替换的一整块上的合法下标不算
/// 越界**——那一镜照样在 `unit.shots` 里，只是给不了精确帧位置（见
/// [_factsOf] 上方那段注释），返回的是一份没有 `frames`/`tc`/
/// `durationFrames` 的正常详情，不是 null。
///
/// `null` 和 `{'framesUnavailable': ...}` 是两件事，不能共用：前者是
/// 「问的这个下标根本不存在」，后者是「下标本身没问题，但全片的成片位置
/// 算不准，这一镜的帧号也就跟着不作数」（见 [_framesUnavailableNote]）。
/// 下标是不是合法只看 `task.units` 本身的形状，跟算不算得出帧号无关，
/// 所以这层校验要在「算不准就拒答」之前做。
Map<String, dynamic>? subtitleShotReport(
  RenewTask task, {
  required int unitIndex,
  required int shotIndex,
}) {
  final rawUnits = task.units ?? const <SemanticUnit>[];
  if (unitIndex < 0 || unitIndex >= rawUnits.length) return null;
  if (shotIndex < 0 || shotIndex >= rawUnits[unitIndex].shots.length) {
    return null;
  }

  final whole = wholeDurationsOf(task);
  if (whole.unknown.isNotEmpty) {
    return {'framesUnavailable': _framesUnavailableNote(whole.unknown)};
  }

  final ctx = _contextOf(task, whole.durations);

  final f = _factsOf(
    frames: ctx.frames,
    timeline: ctx.timeline,
    units: ctx.units,
    replacements: ctx.replacements,
    track: ctx.track,
    originalSentences: ctx.sentences,
    unitIndex: unitIndex,
    shotIndex: shotIndex,
  );

  final unitStart = ctx.timeline.startOf(unitIndex);
  final shotOffset = f.shot.startMs - f.unit.startMs;
  final fpsDouble = ctx.frames.fps.num / ctx.frames.fps.den;
  // 整块段落上，行的帧号跟 shot 级的帧号是同一种假精度：
  // 这里的镜头偏移量的是原片，而那一段在成片里的长度跟着素材走，
  // 偏移根本不成立。文本是真的，帧号不是——所以只报文本
  final lineRows = [
    for (var i = 0; i < f.lines.length; i++)
      _lineRow(f.lines[i], i, unitStart, shotOffset, fpsDouble, f.by,
          hasFrames: f.span != null),
  ];

  // **没过滤过的全部镜头**：隔壁是不是整体替换的一整块，「隔壁」还是它，
  // 不能因为它算不出帧位置就当它不存在、指向更远的一镜——那样判断串字的
  // 依据本身就是错的
  final allShots = _allShots(ctx.units);
  final pos =
      allShots.indexWhere((p) => p.unit == unitIndex && p.shot == shotIndex);
  final prev = pos > 0 ? _neighbourRow(ctx, allShots[pos - 1]) : null;
  final next = pos >= 0 && pos < allShots.length - 1
      ? _neighbourRow(ctx, allShots[pos + 1])
      : null;

  final span = f.span;
  return {
    'at': _at(unitIndex, shotIndex),
    // 给不了精确帧位置（整体替换的一整块）就整个键不出现，不编一个
    if (span != null) 'frames': [span.first, span.last],
    if (span != null)
      'tc': '${ctx.frames.tc(span.first)} → ${ctx.frames.tc(span.last)}',
    if (span != null) 'durationFrames': span.frameCount,
    'voice': {'source': f.voice.source.name, 'note': f.voice.note},
    'heard': _heardMap(f.heard),
    'lines': lineRows,
    'neighbours': {
      if (prev != null) 'prev': prev,
      if (next != null) 'next': next,
    },
    if (f.problems.isNotEmpty)
      'problems': [
        for (final p in f.problems) {'kind': p.kind, 'note': p.note},
      ],
  };
}

Map<String, dynamic> _heardMap(Heard heard) => {
      'text': heard.text,
      if (heard.words != null)
        'words': [
          for (final w in heard.words!)
            {
              'text': w.text,
              'frames': [w.firstFrame, w.lastFrame],
              if (w.confidence != null) 'confidence': w.confidence,
              if (w.spillsInto != null) 'spillsInto': w.spillsInto,
            },
        ],
      if (heard.note != null) 'note': heard.note,
    };

/// 字幕存的是**镜头内毫秒**，报的时候换算成**成片绝对帧**：
/// `frames.frameAt(单元成片起点 + 镜头在单元内的偏移 + 行内偏移)`。
/// 首尾各算一次，规则跟 shot 边界（[ComposedFrames.shotSpan]）一致——
/// 相邻两行不共享任何一帧。
///
/// [hasFrames] 为 false 时（整块段落，`shotSpan` 为 null）不算这个数、
/// 也不报 `frames` 键——见调用点那句注释：这里的镜头偏移量的是原片，
/// 而整块替换那一段在成片里的长度跟着素材走，偏移根本不成立，是跟
/// shot 级的 `frames`/`tc`/`durationFrames` 同一种假精度，只是藏在
/// 更低一层。文本是真的，照报；帧号不是，不编
Map<String, dynamic> _lineRow(
  SubtitleLine l,
  int index,
  int unitStartMs,
  int shotOffsetMs,
  double fpsDouble,
  String by, {
  required bool hasFrames,
}) {
  final frames = hasFrames
      ? FrameSpan.fromMs(unitStartMs + shotOffsetMs + l.startMs,
          unitStartMs + shotOffsetMs + l.endMs, fpsDouble)
      : null;
  return {
    'i': index,
    if (frames != null) 'frames': [frames.first, frames.last],
    'text': l.text,
    'by': by,
  };
}

/// 相邻镜的字幕文本——判断串字必须看得到隔壁。只取显示什么，
/// 不重算听到什么/问题，那些只对“当前这一镜”有意义
Map<String, dynamic> _neighbourRow(
  ({
    List<SemanticUnit> units,
    List<UnitReplacement> replacements,
    ComposedTimeline timeline,
    ComposedFrames frames,
    SubtitleTrack track,
    List<AsrSentence> sentences,
  }) ctx,
  ({int unit, int shot}) at,
) {
  final unit = ctx.units[at.unit];
  final shot = unit.shots[at.shot];
  final lines = subtitleLinesForSlot(
    track: ctx.track,
    sentences: ctx.sentences,
    unitUid: unit.uid,
    shotIndex: at.shot,
    slotStartMs: shot.startMs,
    slotEndMs: shot.endMs,
    onMaterialBase: hasOwnBaseShots(unit),
    baseSentences: unit.baseSentences,
    baseSlotStartMs: shot.startMs - unit.startMs,
    baseSlotEndMs: shot.endMs - unit.startMs,
  );
  return {
    'at': _at(at.unit, at.shot),
    'lines': [for (final l in lines) l.text],
  };
}
