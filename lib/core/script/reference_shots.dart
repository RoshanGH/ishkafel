/// 参考片的**视觉镜头层**：把全片切点变成完整镜头，再把台词关联上去。
///
/// 为什么单独一支：视觉镜头的真实边界跟台词边界毫无关系。老实现拿
/// 「台词区间 ∩ 视觉切点」当参考镜——原片一个 3 秒的画面正好跨在两句
/// 台词的接缝上，就被切成 3 毫秒 + 剩下的两截，前一截根本不是镜头，
/// 是上一个镜头的尾巴（真机任务 hluyggdhpb：45 个参考镜里 19 个短于
/// 1 秒，最短 3 毫秒）。拿这种碎片抽帧去打标、去以图搜视频，结论当然
/// 是错的，而且错得很像「AI 不行」，极难查。
///
/// 现在两层各自成立：
/// - 镜头层：边界只由画面切点决定，不管它跨了几句台词、或者压根没台词
/// - 台词层：决定成片时间
/// 中间是关联（这一句对应哪几镜，一镜可被多句共用），不是切割。
library;

import '../analysis/providers.dart';
import 'script_doc.dart';

/// 全片完整镜头序列：`[(0,c1), (c1,c2), …, (cn, 总时长)]`。
///
/// 返回空表示**没有可信的镜头层**（一个切点都没有，或时长未知），
/// 调用方应退回老算法而不是硬造一个「整片一镜」——那会让每一行都指向
/// 同一个几十秒的「镜头」，比没有更糟。
List<(int, int)> buildWholeShots({
  required List<int> cuts,
  required int durationMs,
}) {
  if (durationMs <= 0) return const [];
  final points = <int>{
    0,
    for (final c in cuts)
      if (c > 0 && c < durationMs) c,
    durationMs,
  }.toList()
    ..sort();
  // 只有首尾两个点 = 没有一个有效切点
  if (points.length < 3) return const [];

  final out = <(int, int)>[];
  for (var i = 0; i < points.length - 1; i++) {
    final s0 = points[i];
    final e0 = points[i + 1];
    if (e0 - s0 < refShotMinMs && out.isNotEmpty) {
      final last = out.removeLast();
      out.add((last.$1, e0));
    } else {
      out.add((s0, e0));
    }
  }
  // 开头那一镜太碎时只能并入后一镜（前面没有可并的）
  if (out.length > 1 && out.first.$2 - out.first.$1 < refShotMinMs) {
    final merged = (out[0].$1, out[1].$2);
    out.removeAt(0);
    out[0] = merged;
  }
  return List.unmodifiable(out);
}

/// 台词 + 全片切点 → 脚本行（按时间排序）。
///
/// - 每句台词按**时间重叠**关联到它覆盖的那些完整镜头
/// - 没被任何台词覆盖的镜头 → **画面行**（`ScriptLineType.visual`，
///   时长手填为这一镜的长度）。参考片开头的吸睛段、中间空镜、结尾产品
///   定格都落在台词区间之外，不成行的话复刻出来的片子会直接少掉这些段
/// - 拿不到可信的镜头层时退回老算法（一句一行、按台词边界切）
List<ScriptLine> buildReferenceLines({
  required List<AsrSentence> sentences,
  required List<int> cuts,
  required int durationMs,
}) {
  final spoken = [
    for (final s in sentences)
      if (s.text.trim().isNotEmpty && s.endMs > s.startMs) s,
  ];
  final shots = buildWholeShots(cuts: cuts, durationMs: durationMs);
  if (shots.isEmpty) {
    return [
      for (final s in spoken)
        ScriptLine.create(
          text: s.text.trim(),
          reference: LineRef(
            startMs: s.startMs,
            endMs: s.endMs,
            cuts: [
              for (final c in cuts)
                if (c > s.startMs && c < s.endMs) c,
            ],
            words: _words(s),
          ),
        ),
    ];
  }

  final covered = <int>{};
  // (排序键, 同键内的次序, 行)——画面行按镜头起点排，配音行按它第一镜的
  // 起点排，同一镜里的几句再按台词起点排
  final entries = <(int, int, ScriptLine)>[];
  for (final s in spoken) {
    final indexes = _shotsFor(shots, s);
    if (indexes.isEmpty) {
      // 理论上不会发生（镜头铺满全片），真出现了也不能把这一句弄丢
      entries.add((
        s.startMs,
        s.startMs,
        ScriptLine.create(
          text: s.text.trim(),
          reference: LineRef(
              startMs: s.startMs, endMs: s.endMs, words: _words(s)),
        ),
      ));
      continue;
    }
    covered.addAll(indexes);
    final first = shots[indexes.first];
    final last = shots[indexes.last];
    entries.add((
      first.$1,
      s.startMs,
      ScriptLine.create(
        text: s.text.trim(),
        reference: LineRef(
          startMs: s.startMs,
          endMs: s.endMs,
          shotStartMs: first.$1,
          shotEndMs: last.$2,
          // 跨度内部的切点：这几镜之间的边界
          cuts: [
            for (final i in indexes.skip(1)) shots[i].$1,
          ],
          // 词级时间戳留下来：找镜头面板按参考镜检索时，要裁出
          // 「这一镜时段说了哪几个字」当检索词
          words: _words(s),
        ),
      ),
    ));
  }

  for (var i = 0; i < shots.length; i++) {
    if (covered.contains(i)) continue;
    final (start, end) = shots[i];
    entries.add((
      start,
      start,
      ScriptLine.create(
        reference: LineRef(
            startMs: start, endMs: end, shotStartMs: start, shotEndMs: end),
      ).withManualMs(end - start),
    ));
  }

  entries.sort((a, b) {
    final byShot = a.$1.compareTo(b.$1);
    return byShot != 0 ? byShot : a.$2.compareTo(b.$2);
  });
  return [for (final e in entries) e.$3];
}

List<VoiceWord> _words(AsrSentence s) => [
      for (final w in s.words)
        VoiceWord(text: w.text, startMs: w.startMs, endMs: w.endMs),
    ];

/// 这一句压在哪几镜上（下标，升序、连续）。
///
/// 两端**重叠太短的镜头一律甩掉**（见 [refShotMinOverlapMs]）：一句台词
/// 的开头压着上一镜几毫秒的尾巴，那一镜是上一句的画面，不是这一句的。
/// 但至少留一镜——一句台词总得有个画面可依据。
List<int> _shotsFor(List<(int, int)> shots, AsrSentence s) {
  final hit = <int>[];
  for (var i = 0; i < shots.length; i++) {
    final (start, end) = shots[i];
    if (start < s.endMs && end > s.startMs) hit.add(i);
  }
  var lo = 0;
  var hi = hit.length - 1;
  int overlap(int i) {
    final (start, end) = shots[hit[i]];
    final from = start > s.startMs ? start : s.startMs;
    final to = end < s.endMs ? end : s.endMs;
    return to - from;
  }

  while (hi > lo && overlap(lo) < refShotMinOverlapMs) {
    lo++;
  }
  while (hi > lo && overlap(hi) < refShotMinOverlapMs) {
    hi--;
  }
  return [for (var i = lo; i <= hi; i++) hit[i]];
}
