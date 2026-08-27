import 'script_doc.dart';

/// 台词上「选中的字」与「词序号」之间的换算。划词建镜的地基。
///
/// 难点是**词和原文对不齐**：ASR 给的词里通常没有标点（「如果」「你」
/// 「觉得」…），界面上显示的却是带标点的原文。字幕就在这里栽过——
/// 把空隙一律当标点还原，遇到「69.91」这种被并成一个词的数字直接崩掉，
/// 出现一字一屏（见 subtitle_overlay 的 `_restorePunctuation`）。
///
/// 所以这里的规矩是：**按词在原文里的实际位置对齐**（indexOf 顺序推进），
/// 对不上的词留空、跟着相邻词走，绝不猜。
typedef WordRange = ({int start, int end});
typedef CharRange = ({int start, int end});

/// 每个词在原文里的字符区间；对不上的位置为 null
List<CharRange?> wordCharOffsets(String source, List<VoiceWord> words) {
  final out = <CharRange?>[];
  var pos = 0;
  for (final w in words) {
    final idx = w.text.isEmpty ? -1 : source.indexOf(w.text, pos);
    if (idx < 0) {
      out.add(null);
      pos = (pos + w.text.length).clamp(0, source.length);
      continue;
    }
    out.add((start: idx, end: idx + w.text.length));
    pos = idx + w.text.length;
  }
  return out;
}

/// 选中的字符区间 `[from, to)` 覆盖了哪几个词。
///
/// **选到半个词也算上整个词**——一个词是配音时间戳的最小单位，切一半
/// 就没有对应的时长可算了。返回 null = 没选中任何词。
WordRange? wordRangeOf(
    String source, List<VoiceWord> words, int from, int to) {
  if (words.isEmpty || to <= from) return null;
  final offsets = wordCharOffsets(source, words);
  int? start;
  int? end;
  for (var i = 0; i < offsets.length; i++) {
    final o = offsets[i];
    if (o == null) continue;
    // 有交集就算这个词被选中了（半个也算）
    if (o.end > from && o.start < to) {
      start ??= i;
      end = i + 1;
    }
  }
  return start == null || end == null ? null : (start: start, end: end);
}

/// 词区间 `[start, end)` 在原文里占哪一段字符。界面拿它给已占用的字上底色
CharRange? charRangeOf(
    String source, List<VoiceWord> words, int start, int end) {
  if (words.isEmpty) return null;
  final offsets = wordCharOffsets(source, words);
  final a = start.clamp(0, offsets.length);
  final b = end.clamp(0, offsets.length);
  int? from;
  int? to;
  for (var i = a; i < b; i++) {
    final o = offsets[i];
    if (o == null) continue;
    from ??= o.start;
    to = o.end;
  }
  return from == null || to == null ? null : (start: from, end: to);
}

/// 这几镜占住了原文的哪些字。界面照着上底色，人一眼看出哪儿还能划
List<CharRange> takenCharRanges(
        String source, List<VoiceWord> words, List<WordRange> bounds) =>
    [
      for (final b in bounds)
        ?charRangeOf(source, words, b.start, b.end),
    ];

/// 选区碰到已占用的字了吗。
///
/// 碰到就**不给「加分镜」这个按钮**——人不做无效操作，比做完再被拒绝好。
/// 想改就删掉那一镜，那几个字自动恢复成可划
bool overlapsTaken(List<CharRange> taken, int from, int to) {
  for (final t in taken) {
    if (t.end > from && t.start < to) return true;
  }
  return false;
}
