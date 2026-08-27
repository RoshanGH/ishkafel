import 'script_doc.dart';

/// 一处「字幕盖不住语音」的问题
typedef SubtitleMismatch = ({int screenIndex, String message});

/// 手写字幕的字数明显少于这一屏实际念了多少字时，点名。
///
/// 真机上出过这么一行：第 1 屏覆盖 26 个字、4.7 秒，人手写的字幕只有
/// 8 个字——那 4.7 秒配音一直在念后面 18 个字，字幕却不动，一路漏到成片。
///
/// 触发它的是一次正常操作（改字幕），但软件一声不吭就收下了。
/// **能被正常操作轻易做出来、做出来还没人吭声的坏状态，是程序的责任**，
/// 所以这条要进 blocking：不是拦着不让写，是不让它悄悄漏进成片。
///
/// 判据刻意宽松（少一半以上才报）：同音改写、去掉语气词、把「一百块」
/// 写成「100 块」都是正常操作，不该被啰嗦。
List<SubtitleMismatch> subtitleMismatches(ScriptLine line, {double ratio = 0.5}) {
  final vo = line.voiceover;
  final manual = line.subtitleScreens;
  if (vo == null || manual == null || vo.words.isEmpty) return const [];

  final words = vo.words;
  final out = <SubtitleMismatch>[];
  for (var i = 0; i < manual.length; i++) {
    final text = manual[i].text;
    // null = 没改过（用自动切片）；'' = 人明确说这屏不出字
    if (text == null || text.isEmpty) continue;
    final from = manual[i].startWord.clamp(0, words.length);
    final to = (i + 1 < manual.length ? manual[i + 1].startWord : words.length)
        .clamp(0, words.length);
    if (to <= from) continue;

    final spoken = [for (var k = from; k < to; k++) words[k].text].join();
    if (spoken.isEmpty) continue;
    if (text.length >= spoken.length * ratio) continue;

    final ms = words[to - 1].endMs - words[from].startMs;
    out.add((
      screenIndex: i,
      message: '第 ${i + 1} 屏字幕只有 ${text.length} 个字，'
          '但这一屏要念 ${spoken.length} 个字、${(ms / 1000).toStringAsFixed(1)} 秒'
          '——中间那段配音在响，字幕却停着不动。'
          '把这一屏切开，或者把字幕补齐',
    ));
  }
  return out;
}
