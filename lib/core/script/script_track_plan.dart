import '../playback/track_plan.dart';
import 'script_doc.dart';
import 'shot_allocation.dart';

/// 一个镜头段的画面来源：文件路径 + 从文件的哪一刻开始播。
///
/// 原速镜头直接播素材本体（inMs = 框选起点）；变速镜头播的是预渲染好的
/// 对齐切片（从 0 开始、时长恰为 allocMs——EDL 没有逐段倍速，见 Edl 注释）
class ShotSource {
  final String path;
  final int inMs;
  const ShotSource(this.path, {this.inMs = 0});
}

/// 整片预览的构建结果：可播的轨 + 这一轮跳过了什么（必须说出来）
class ScriptPlanResult {
  final TrackPlan plan;

  /// 被跳过的行（0 起下标）→ 人话原因。预览可以少一行——人还在编排——
  /// 但少了哪行、为什么少，必须点名
  final Map<int, String> skippedLines;

  /// 进了预览的行 → 它在预览轴上的起点（「点句子跳播」靠它）
  final Map<int, int> lineStarts;

  const ScriptPlanResult({
    required this.plan,
    required this.skippedLines,
    this.lineStarts = const {},
  });

  bool get isEmpty => plan.isEmpty;
}

/// 把脚本拼成预览轨：画面 = 各行镜头序列顺序相接，口播 = 各行配音。
///
/// **只拼就绪的行**：行的时长根不存在（没配音/没填时长）、镜头没挑、
/// 分配没做完、素材没下载完，这一行都进不了预览——预览轴是「已就绪内容」
/// 的连续拼接，跳过的行逐条点名，绝不静默把片子变短。
ScriptPlanResult buildScriptTrackPlan(
  ScriptDoc doc, {
  required ShotSource? Function(LineShot shot) sourceOf,

  /// 配乐曲子的本地路径（materialId → path）；null = 还没下载好，
  /// 该段先不铺（由调用方交代下载状态）
  String? Function(int materialId)? bgmPathOf,
}) {
  final video = <TrackSegment>[];
  final voice = <TrackSegment>[];
  final skipped = <int, String>{};
  final lineStarts = <int, int>{};
  var cursorMs = 0;

  for (var i = 0; i < doc.lines.length; i++) {
    final line = doc.lines[i];
    final blank =
        line.text.trim().isEmpty && line.shots.isEmpty; // 纯空行不值得点名
    if (blank) continue;

    final root = ShotAllocation.rootMsOf(line);
    if (root == null || root <= 0) {
      skipped[i] = line.type == ScriptLineType.voiced
          ? '还没生成配音（配音时长是这一行的根）'
          : '还没确定时长';
      continue;
    }
    if (line.shots.isEmpty) {
      skipped[i] = '还没挑镜头';
      continue;
    }
    if (line.shots.any((s) => s.allocMs == null)) {
      skipped[i] = '镜头还没分时长';
      continue;
    }
    final sources = <ShotSource>[];
    String? notReady;
    for (final shot in line.shots) {
      final src = sourceOf(shot);
      if (src == null) {
        notReady = '素材还没就绪（下载或变速切片未完成）';
        break;
      }
      sources.add(src);
    }
    if (notReady != null) {
      skipped[i] = notReady;
      continue;
    }

    lineStarts[i] = cursorMs;
    var shotAt = cursorMs;
    for (var j = 0; j < line.shots.length; j++) {
      final shot = line.shots[j];
      video.add(TrackSegment(
        atMs: shotAt,
        durationMs: shot.allocMs!,
        source: sources[j].path,
        inMs: sources[j].inMs,
      ));
      // 画面行没有配音，用素材自己的声音（设计稿：画面行有画面有音乐
      // 或用分镜自己的声音）；配音行的声音轨在下面统一铺配音
      if (line.type == ScriptLineType.visual) {
        voice.add(TrackSegment(
          atMs: shotAt,
          durationMs: shot.allocMs!,
          source: sources[j].path,
          inMs: sources[j].inMs,
        ));
      }
      shotAt += shot.allocMs!;
    }
    // 行区间跟**实际分配**走：画面轨必须连续（EDL 是顺序相接的，留洞会让
    // 画面与声音错位）。分配不足根时配音随画面截断——缺口在分配警告里
    // 已经点过名，预览如实播出「画面只有这么长」
    final lineSpanMs = shotAt - cursorMs;
    final vo = line.voiceover;
    if (line.type == ScriptLineType.voiced && vo != null && lineSpanMs > 0) {
      voice.add(TrackSegment(
        atMs: cursorMs,
        durationMs: root < lineSpanMs ? root : lineSpanMs,
        source: vo.audioPath,
      ));
    }
    cursorMs = shotAt;
  }

  // 配乐段：行区间 → 预览轴区间（只算进了预览的行）。
  // 相邻段同一首曲子时合并成一个 clip——播放连续不重头
  // （BgmSegment 引擎的同一语义）
  final bgm = <BgmTrackSegment>[];
  for (final seg in doc.bgmSegments) {
    final path = bgmPathOf?.call(seg.material.id);
    if (path == null) continue;
    int? fromMs;
    var toMs = 0;
    for (var i = seg.startLine; i <= seg.endLine && i < doc.lines.length; i++) {
      final start = lineStarts[i];
      if (start == null) continue; // 该行没进预览
      fromMs ??= start;
      final nextStart = lineStarts.entries
          .where((e) => e.key > i)
          .fold<int?>(null, (a, e) => a == null || e.value < a ? e.value : a);
      toMs = nextStart ?? cursorMs;
    }
    if (fromMs == null || toMs <= fromMs) continue;
    final last = bgm.isEmpty ? null : bgm.last;
    if (last != null &&
        last.clip.source == path &&
        last.clip.endMs == fromMs &&
        last.volume == seg.volume) {
      // 相邻同曲：并成一段，接着播不重头
      bgm[bgm.length - 1] = BgmTrackSegment(
        clip: TrackSegment(
            atMs: last.clip.atMs,
            durationMs: toMs - last.clip.atMs,
            source: path),
        volume: last.volume,
        sourceDurationMs: last.sourceDurationMs,
      );
    } else {
      bgm.add(BgmTrackSegment(
        clip: TrackSegment(
            atMs: fromMs, durationMs: toMs - fromMs, source: path),
        volume: seg.volume,
        sourceDurationMs: seg.material.durationMs,
      ));
    }
  }
  return ScriptPlanResult(
    plan: TrackPlan(video: video, voice: voice, bgm: bgm),
    skippedLines: skipped,
    lineStarts: lineStarts,
  );
}
