import '../editing/frame_time.dart';
import 'heard_words.dart';
import 'subtitle_overlay.dart';

/// 一条机械可查的毛病。[kind] 给程序认，[note] 给人和 Agent 读
class SubtitleProblem {
  final String kind;
  final String note;

  const SubtitleProblem({required this.kind, required this.note});
}

/// 这一镜的字幕有哪些**机械可查的**毛病。
///
/// **不报的**：断句好不好看、读着顺不顺、错别字。那些是判断，判断归 Agent
/// ——软件只报事实（与 2026-09-20 同日定下的检索原则同源）。
///
/// 错别字尤其查不了：ASR 自己就听错了，**参照物本身是错的**。
/// 软件能给的只是判断材料（产品名、标签词表、词的置信度）。
List<SubtitleProblem> subtitleProblemsOf({
  required FrameSpan? shotSpan,
  required Heard heard,
  required List<SubtitleLine> lines,
  required int slotDurationMs,
}) {
  final out = <SubtitleProblem>[];

  // 检查：字跨镜头边界
  for (final w in heard.words ?? const <HeardWord>[]) {
    if (w.spillsInto == null) continue;
    out.add(SubtitleProblem(
      kind: 'wordSplit',
      note: '「${w.text}」从第 ${w.firstFrame} 帧说到第 ${w.lastFrame} 帧，'
          '跨过了这一镜的末帧（${shotSpan?.last}）——后半截落在 ${w.spillsInto} 上',
    ));
  }

  // 检查：空段、越界、打架
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    // 空文本或零长度
    if (l.text.trim().isEmpty || l.endMs <= l.startMs) {
      out.add(SubtitleProblem(
        kind: 'empty',
        note: '第 ${i + 1} 段是空的（文本为空或时长为 0），'
            '它在轨上点不中，在画面上也只是一闪',
      ));
    }
    // 越出镜头
    if (l.startMs < 0 || l.endMs > slotDurationMs) {
      out.add(SubtitleProblem(
        kind: 'outOfSlot',
        note: '第 ${i + 1} 段越出了这一镜（这一镜只有 $slotDurationMs 毫秒）'
            '——出了界根本没地方烧',
      ));
    }
    // 与前一段打架
    if (i > 0 && l.startMs < lines[i - 1].endMs) {
      out.add(SubtitleProblem(
        kind: 'overlap',
        note: '第 $i 段和第 ${i + 1} 段在时间上打架，'
            '两句字同时挂在画面上就是两层字',
      ));
    }
  }

  // 检查：有声音但无字幕，或无声音但有字幕
  final hasVoice = heard.text.trim().isNotEmpty;
  final hasLines = lines.any((l) => l.text.trim().isNotEmpty);
  if (hasVoice && !hasLines) {
    out.add(SubtitleProblem(
      kind: 'heardButSilent',
      note: '这一镜听得到「${heard.text}」，却一行字幕都没有',
    ));
  }
  if (!hasVoice && hasLines) {
    out.add(SubtitleProblem(
      kind: 'silentButCaptioned',
      note: '这一镜没有台词来源${heard.note == null ? '' : '（${heard.note}）'}，'
          '却挂着字幕——它是从哪来的？',
    ));
  }

  return List.unmodifiable(out);
}
