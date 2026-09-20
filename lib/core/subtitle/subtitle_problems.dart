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

  for (final w in heard.words ?? const <HeardWord>[]) {
    final landsOn = w.spillsInto;
    if (landsOn == null) continue;
    // **spillsInto 不一定是镜头标号**：上游说不出落在哪一镜时，给的是
    // 一句实话（「下一段是整段替换，没有镜头可定位」「片尾之后」）。
    // 无脑套「落在 X 上」会拼出「后半截落在 片尾之后 上」这种病句——
    // 而这条 note 是整件事里最该被读懂的一句
    final where = RegExp(r'^U\d+S\d+$').hasMatch(landsOn)
        ? '落在 $landsOn 上'
        : landsOn;
    out.add(SubtitleProblem(
      kind: 'wordSplit',
      note: '「${w.text}」从第 ${w.firstFrame} 帧说到第 ${w.lastFrame} 帧，'
          '跨过了这一镜的末帧（${shotSpan?.last ?? '未知'}）——后半截$where',
    ));
  }

  var maxEndSoFar = 0;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.text.trim().isEmpty || l.endMs <= l.startMs) {
      out.add(SubtitleProblem(
        kind: 'empty',
        note: '第 ${i + 1} 段是空的（文本为空或时长为 0），'
            '它在轨上点不中，在画面上也只是一闪',
      ));
    }
    if (l.startMs < 0 || l.endMs > slotDurationMs) {
      out.add(SubtitleProblem(
        kind: 'outOfSlot',
        note: '第 ${i + 1} 段越出了这一镜（这一镜只有 $slotDurationMs 毫秒）'
            '——出了界根本没地方烧',
      ));
    }
    // **跟「到目前为止最大的 endMs」比，不是只跟紧邻的上一段比。**
    // 只比紧邻的话，[0,1000][100,200][300,400] 这种被长段包住的情形
    // 会漏报——而 overlap 是一条事实声明，不该有缺口
    if (i > 0 && l.startMs < maxEndSoFar) {
      out.add(SubtitleProblem(
        kind: 'overlap',
        note: '第 ${i + 1} 段和前面某一段在时间上打架，'
            '两句字同时挂在画面上就是两层字',
      ));
    }
    if (l.endMs > maxEndSoFar) maxEndSoFar = l.endMs;
  }

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
