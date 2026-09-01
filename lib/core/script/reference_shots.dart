/// 参考片 → 脚本行：**和替换裂变走同一套切分**。
///
/// 替换裂变怎么切分子和原子，这里就怎么切行和行内的参考分镜：
///
/// - **分子**（台词语义单元）→ 一行。边界由 [SegmentationBuilder] 吸附到
///   镜头边界／静音谷／帧
/// - **原子**（视觉镜头）→ 这一行点进去看到的那几个参考分镜，
///   由单元内部落入的镜头边界切出，**必须整个落在这一行里**
///   （见 `SemanticUnit.shotsStrictlyNested`）
///
/// 这里曾经另写过一套「一句一行 + 事后关联镜头跨度」。那套等于永远走
/// [VolcanoSemanticSplitter] 的降级路径（AI 分组失败才用的一句一单元），
/// 还打破了「原子必须在分子内」的约束——于是一个完整镜头横跨三行，
/// 人看到的是同一个画面被切成 0.6 秒、0.4 秒、1.6 秒三张卡，
/// 「比原子还碎」。同一件事两处算，这个项目已经栽过三次。
library;

import '../analysis/providers.dart';
import '../analysis/segmentation_builder.dart';
import '../models/semantic_unit.dart';
import 'script_doc.dart';

/// 一段没有台词的画面要多长，才值得单独成一行。
///
/// 参考片开头的吸睛段、中间的空镜、结尾的产品定格都落在台词之外——
/// 不成行的话复刻出来的片子会直接少掉这些段。短于这个长度的间隙不单独成行，
/// 交给边界吸附并进相邻单元（闪一下的空隙不是一个段落）。
const int visualGapMinMs = 900;

/// 把**没有台词的长间隙**补成空台词草稿，让它们各自成为一个单元 → 画面行。
///
/// 替换裂变不需要这一步（它保台词换画面，无台词段落本就属于相邻单元）；
/// 脚本成片要复刻整条片子，那些段落必须成行，否则复刻的片子少一截。
List<UnitDraft> draftsWithVisualGaps({
  required List<UnitDraft> drafts,
  required int durationMs,
}) {
  if (durationMs <= 0) return drafts;
  final sorted = [...drafts]..sort((a, b) => a.startMs.compareTo(b.startMs));
  final out = <UnitDraft>[];
  var cursor = 0;
  for (final d in sorted) {
    if (d.startMs - cursor >= visualGapMinMs) {
      out.add(UnitDraft(startMs: cursor, endMs: d.startMs, transcript: ''));
    }
    out.add(d);
    cursor = d.endMs > cursor ? d.endMs : cursor;
  }
  if (durationMs - cursor >= visualGapMinMs) {
    out.add(UnitDraft(startMs: cursor, endMs: durationMs, transcript: ''));
  }
  return out;
}

/// 语义单元（分子）→ 脚本行。
///
/// 一个单元一行；这一行的参考分镜就是单元内部的那几镜（原子）。
/// 没有台词的单元成**画面行**：时长手填为这一段的长度，因为它没有配音，
/// 而这条线的时间根是配音时长——不填的话它在成片里长度为 0。
List<ScriptLine> linesFromUnits({
  required List<SemanticUnit> units,
  required List<AsrSentence> sentences,
}) {
  final out = <ScriptLine>[];
  for (final u in units) {
    // 单元内部的镜头边界 = 这一行的参考分镜切点（第一镜的起点就是行首，
    // 不算切点）
    final cuts = [for (final s in u.shots.skip(1)) s.startMs];
    final text = u.transcript.trim();
    if (text.isEmpty) {
      out.add(ScriptLine.create(
        reference: LineRef(startMs: u.startMs, endMs: u.endMs, cuts: cuts),
      ).withManualMs(u.durationMs));
      continue;
    }
    out.add(ScriptLine.create(
      text: text,
      reference: LineRef(
        startMs: u.startMs,
        endMs: u.endMs,
        cuts: cuts,
        // 词级时间戳：找镜头面板要按「这一镜时段说了哪几个字」当检索词
        words: _wordsIn(sentences, u.startMs, u.endMs),
      ),
    ));
  }
  return out;
}

/// 落在这个单元时段里的词（按词的时间中点归属，边界上的词不重复计入两行）
List<VoiceWord> _wordsIn(List<AsrSentence> sentences, int startMs, int endMs) {
  final out = <VoiceWord>[];
  for (final s in sentences) {
    for (final w in s.words) {
      final mid = (w.startMs + w.endMs) ~/ 2;
      if (mid >= startMs && mid < endMs) {
        out.add(VoiceWord(text: w.text, startMs: w.startMs, endMs: w.endMs));
      }
    }
  }
  out.sort((a, b) => a.startMs.compareTo(b.startMs));
  return out;
}
