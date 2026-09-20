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
  final FrameSpan span;
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

/// 算出第 [unitIndex]/[shotIndex] 镜的四步事实。调用前必须先确认
/// `frames.shotSpan(unitIndex, shotIndex)` 非 null——整块段落（整体替换、
/// 没有自己镜头）没有帧位置可言，这里不做这层校验，交给调用方（两处都已经
/// 只在“可定位”的镜头上调它，见 [_addressableShots]）。
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
  final span = frames.shotSpan(unitIndex, shotIndex)!;
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

/// 全片有哪些镜头**可定位**（`frames.shotSpan` 非 null）。
///
/// 整体替换、且没自己切过镜头的单元是一整块——原片的切分在成片里已经不
/// 存在了，编一个位置出来是假精度（见 [ComposedFrames.shotSpan] 的注释）。
/// 这类单元的镜头在全片列表里整段不出现，问它的单镜详情也如实答 null——
/// 这跟“下标越界”是同一件事的两种成因，答法理应一样。
List<({int unit, int shot})> _addressableShots(
  ComposedFrames frames,
  List<SemanticUnit> units,
) =>
    [
      for (var u = 0; u < units.length; u++)
        for (var s = 0; s < units[u].shots.length; s++)
          if (frames.shotSpan(u, s) != null) (unit: u, shot: s),
    ];

/// 建一次全片都要用到的上下文，全片报告和单镜报告共用，
/// 不许各自再拼一份——那正是这个模块要堵住的洞
({
  List<SemanticUnit> units,
  List<UnitReplacement> replacements,
  ComposedTimeline timeline,
  ComposedFrames frames,
  SubtitleTrack track,
  List<AsrSentence> sentences,
}) _contextOf(RenewTask task) {
  final units = task.units ?? const <SemanticUnit>[];
  final replacements = task.replacementsFor(units);
  // 整体替换的单元在成片里有多长，全项目只有 wholeDurationsOf 这一处算
  // （见 task_view.dart）。这里不额外拦「候选时长还没探出来」的单元——
  // 拦不拦，heardInShot / subtitleProblemsOf 已经会把这类过渡态如实报出来
  // （台词来源报 replaced、听到的是空、字幕却还挂着，会被 silentButCaptioned
  // 点名），比在这里整块拒答更诚实
  final durations = wholeDurationsOf(task).durations;
  final timeline = ComposedTimeline.of(units: units, wholeDurations: durations);
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

/// 全片那份——`subtitle show <任务>`。一镜一行，扫得动。
Map<String, dynamic> subtitleReport(RenewTask task) {
  final ctx = _contextOf(task);
  final addressable = _addressableShots(ctx.frames, ctx.units);

  final shots = [
    for (final pos in addressable)
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
) =>
    {
      'at': _at(unitIndex, shotIndex),
      'unitUid': f.unit.uid,
      'unit': unitIndex,
      'shot': shotIndex,
      'frames': [f.span.first, f.span.last],
      'tc': '${frames.tc(f.span.first)} → ${frames.tc(f.span.last)}',
      'voice': f.voice.source.name,
      'heard': f.heard.text,
      'lines': [for (final l in f.lines) l.text],
      'by': f.by,
      if (f.problems.isNotEmpty)
        'problems': [for (final p in f.problems) p.kind],
    };

/// 单镜那份——`subtitle show <任务> --unit 1 --shot 2`。
///
/// 下标越界、或者落在整体替换的一整块上（没有镜头可定位），一律返回 null，
/// 不抛——这跟全片列表里“这一镜整段不出现”是同一件事
Map<String, dynamic>? subtitleShotReport(
  RenewTask task, {
  required int unitIndex,
  required int shotIndex,
}) {
  final ctx = _contextOf(task);
  if (unitIndex < 0 || unitIndex >= ctx.units.length) return null;
  final unit = ctx.units[unitIndex];
  if (shotIndex < 0 || shotIndex >= unit.shots.length) return null;
  if (ctx.frames.shotSpan(unitIndex, shotIndex) == null) return null;

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
  final lineRows = [
    for (var i = 0; i < f.lines.length; i++)
      _lineRow(f.lines[i], i, unitStart, shotOffset, fpsDouble, f.by),
  ];

  final addressable = _addressableShots(ctx.frames, ctx.units);
  final pos = addressable.indexWhere(
      (p) => p.unit == unitIndex && p.shot == shotIndex);
  final prev = pos > 0 ? _neighbourRow(ctx, addressable[pos - 1]) : null;
  final next = pos >= 0 && pos < addressable.length - 1
      ? _neighbourRow(ctx, addressable[pos + 1])
      : null;

  return {
    'at': _at(unitIndex, shotIndex),
    'frames': [f.span.first, f.span.last],
    'tc': '${ctx.frames.tc(f.span.first)} → ${ctx.frames.tc(f.span.last)}',
    'durationFrames': f.span.frameCount,
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
/// 相邻两行不共享任何一帧
Map<String, dynamic> _lineRow(
  SubtitleLine l,
  int index,
  int unitStartMs,
  int shotOffsetMs,
  double fpsDouble,
  String by,
) {
  final absStart = unitStartMs + shotOffsetMs + l.startMs;
  final absEnd = unitStartMs + shotOffsetMs + l.endMs;
  final span = FrameSpan.fromMs(absStart, absEnd, fpsDouble);
  return {
    'i': index,
    'frames': [span.first, span.last],
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
