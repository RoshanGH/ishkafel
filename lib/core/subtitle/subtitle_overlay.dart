import '../analysis/providers.dart' show AsrSentence, AsrWord;

/// 镜头替换切片上的字幕重渲（纯函数层，不碰进程）。
///
/// 原片的台词字幕烧在画面像素里，替换掉画面它就没了。这里用分析阶段存下的
/// 句级转写（[AsrSentence]，任务里的 `asrSentences`）重新渲染：声音本来就是
/// 原片的，所以字幕内容与时间天然同步；渲染区间只取**被替换的那个坑位**，
/// 保留原片的镜头仍由原片自己的字幕负责。
///
/// **为什么不用 ffmpeg 的 ass/drawtext 滤镜**：新版 Homebrew 的 ffmpeg
/// 已经不带 libass/freetype（真机实测 `No such filter: 'ass'`），同事机器
/// `brew install ffmpeg` 装到的同样是精简版。所以文字交给 macOS 自带的
/// 系统渲染（见 subtitle_rasterizer.dart）渲成透明 PNG，再用**内建的**
/// overlay 滤镜按时间叠上去——overlay 任何 ffmpeg 都有。

/// 一行要渲染的字幕（时间已平移到切片自己的时间轴，0 = 坑位开头）
class SubtitleLine {
  final int startMs;
  final int endMs;
  final String text;

  const SubtitleLine(
      {required this.startMs, required this.endMs, required this.text});
}

/// 毛玻璃遮罩的文本框（输出画面坐标，顶部原点）
class SubtitleBlurBox {
  final int x;
  final int y;
  final int w;
  final int h;

  const SubtitleBlurBox(
      {required this.x, required this.y, required this.w, required this.h});
}

/// 一张渲染好的字幕图和它的显示区间（切片输出时间轴）
class SubtitleOverlayImage {
  final String pngPath;
  final int startMs;
  final int endMs;

  /// 毛玻璃预设时字幕背后要模糊的画面区域；其余预设为 null
  final SubtitleBlurBox? blurBox;

  const SubtitleOverlayImage(
      {required this.pngPath,
      required this.startMs,
      required this.endMs,
      this.blurBox});
}

/// 一段字幕最多多少个字。超过就拆开先后出现——原片字幕的习惯是短句
/// 逐条，一大句 30 字挂满三行既难看又和相邻原片字幕的节奏对不上
const int _maxCharsPerLine = 18;

/// 裁出坑位 [slotStartMs, slotEndMs) 内要显示的字幕行。
///
/// 有词级时间戳时按**词**归属：只显示这段时间里实际说出口的那几个字
/// （词的时间中点落在坑内才算），跨句界的前后半句各归各的镜头；一段太长
/// 还会按标点/停顿拆开先后出现。ASR 的句子边界和标点不可靠，但逐字的
/// 时间戳相当准（真机数据是几十毫秒粒度）——规则全部建立在词时间上。
///
/// 老数据没有词级时间戳时退回整句：显示时间裁到相交区间、文本整句。
List<SubtitleLine> subtitleLinesInSlot({
  required List<AsrSentence> sentences,
  required int slotStartMs,
  required int slotEndMs,
}) {
  final lines = <SubtitleLine>[];
  for (final s in sentences) {
    final start = s.startMs > slotStartMs ? s.startMs : slotStartMs;
    final end = s.endMs < slotEndMs ? s.endMs : slotEndMs;
    if (end <= start) continue; // 不相交（贴边也算不相交，0ms 的闪现毫无意义）
    final text = s.text.trim();
    if (text.isEmpty) continue;

    if (s.words.isEmpty) {
      // 兜底：没有词级时间戳，按整句显示
      lines.add(SubtitleLine(
          startMs: start - slotStartMs,
          endMs: end - slotStartMs,
          text: stripPunctuation(text)));
      continue;
    }

    // 词的时间中点落在坑内的才算「这段时间里说的话」
    final words = _restorePunctuation(s);
    final inSlot = [
      for (final w in words)
        if ((w.startMs + w.endMs) / 2 >= slotStartMs &&
            (w.startMs + w.endMs) / 2 < slotEndMs)
          w,
    ];
    if (inSlot.isEmpty) continue;

    final segments = _splitByLength(inSlot);
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      // 段间无缝衔接：前一段显示到后一段开始，停顿处字幕不闪没
      final segStart = i == 0
          ? (seg.first.startMs > slotStartMs ? seg.first.startMs : slotStartMs)
          : segments[i].first.startMs;
      final rawEnd = i < segments.length - 1
          ? segments[i + 1].first.startMs
          : (seg.last.endMs < slotEndMs ? seg.last.endMs : slotEndMs);
      if (rawEnd <= segStart) continue;
      final text = stripPunctuation(seg.map((w) => w.text).join());
      if (text.isEmpty) continue;
      lines.add(SubtitleLine(
        startMs: segStart - slotStartMs,
        endMs: rawEnd - slotStartMs,
        text: text,
      ));
    }
  }
  return List.unmodifiable(lines);
}

class _TimedWord {
  final int startMs;
  final int endMs;
  String text;
  _TimedWord(this.startMs, this.endMs, this.text);
}

/// 把句子文本里的标点还原到词上（ASR 的词表里通常只有字，标点在句子
/// 文本里）：顺序扫描，词与词之间的字符附加给前一个词的尾巴
List<_TimedWord> _restorePunctuation(AsrSentence s) {
  final out = <_TimedWord>[];
  final text = s.text;
  var pos = 0;
  for (final AsrWord w in s.words) {
    final idx = text.indexOf(w.text, pos);
    if (idx < 0) {
      out.add(_TimedWord(w.startMs, w.endMs, w.text));
      continue;
    }
    if (out.isNotEmpty && idx > pos) {
      out.last.text += text.substring(pos, idx).trim();
    }
    out.add(_TimedWord(w.startMs, w.endMs, w.text));
    pos = idx + w.text.length;
  }
  if (out.isNotEmpty && pos < text.length) {
    out.last.text += text.substring(pos).trim();
  }
  return out;
}

const _clauseEnders = '，。？！；：、…,.?!;:';

/// 渲染文本里的标点全部剥掉（不留空格）——原片字幕就是无标点的堆字
/// 风格，句读靠「逐段出现」的节奏表达。标点只在**拆段**阶段用
/// （[_splitByLength] 优先在标点处切开），不进画面。
String stripPunctuation(String text) => text.replaceAll(
    RegExp('[，。？！；：、…,.?!;:~～·\'"\u201c\u201d\u2018\u2019()（）《》<>\\[\\]【】—-]'),
    '');

/// 超长的词串按上限拆段。切点优先级：窗口内**最后一个带句读标点的词**
/// （语义断点最好读）> 窗口内词间停顿最大处 > 硬切在窗口末尾
List<List<_TimedWord>> _splitByLength(List<_TimedWord> words) {
  final out = <List<_TimedWord>>[];
  var rest = words;
  int charsOf(List<_TimedWord> ws) =>
      ws.fold(0, (n, w) => n + w.text.length);
  while (charsOf(rest) > _maxCharsPerLine) {
    // 累计字数不超上限的最长前缀
    var window = 0;
    var chars = 0;
    while (window < rest.length &&
        chars + rest[window].text.length <= _maxCharsPerLine) {
      chars += rest[window].text.length;
      window++;
    }
    if (window == 0) window = 1; // 单词就超限：也得切走，防死循环
    var cut = -1;
    for (var i = window - 1; i >= 0; i--) {
      final tail = rest[i].text;
      if (tail.isNotEmpty && _clauseEnders.contains(tail[tail.length - 1])) {
        cut = i;
        break;
      }
    }
    if (cut < 0) {
      // 没有标点：在窗口内词间停顿最大处切
      var bestGap = -1;
      for (var i = 0; i < window - 1; i++) {
        final gap = rest[i + 1].startMs - rest[i].endMs;
        if (gap > bestGap) {
          bestGap = gap;
          cut = i;
        }
      }
      if (cut < 0) cut = window - 1;
    }
    out.add(rest.sublist(0, cut + 1));
    rest = rest.sublist(cut + 1);
  }
  if (rest.isNotEmpty) out.add(rest);
  return out;
}

/// 把主画面滤镜链和若干字幕图拼成一条 filter_complex。
///
/// 输入 0 是画面，输入 1..N 是字幕 PNG（与 [overlays] 顺序一致）。
/// overlay 对单帧图片默认重复末帧，所以静态 PNG 全程可用，显隐全靠
/// `enable='between(t,起,止)'`——引号里的逗号不会被 filtergraph 当分隔符。
String subtitleFilterComplex({
  required String baseChain,
  required List<SubtitleOverlayImage> overlays,
}) {
  final parts = StringBuffer('[0:v]$baseChain[b0]');
  for (var i = 0; i < overlays.length; i++) {
    final o = overlays[i];
    final from = _sec(o.startMs);
    final to = _sec(o.endMs);
    final box = o.blurBox;
    if (box != null && box.w > 0 && box.h > 0) {
      // 毛玻璃：把文本框那块**画面**裁出来模糊，再按时间叠回原位——
      // 不是黑条，是磨砂玻璃。模糊半径按框高比例走，大小字号观感一致
      final radius = (box.h / 6).clamp(6, 24).round();
      parts.write(';[b$i]split[s${i}a][s${i}b]'
          ';[s${i}b]crop=${box.w}:${box.h}:${box.x}:${box.y},'
          'boxblur=luma_radius=$radius:luma_power=2:chroma_radius=$radius[bl$i]'
          ";[s${i}a][bl$i]overlay=${box.x}:${box.y}:"
          "enable='between(t,$from,$to)'[g$i]"
          ";[g$i][${i + 1}:v]overlay=0:0:"
          "enable='between(t,$from,$to)'[b${i + 1}]");
    } else {
      parts.write(";[b$i][${i + 1}:v]overlay=0:0:"
          "enable='between(t,$from,$to)'[b${i + 1}]");
    }
  }
  return parts.toString();
}

/// filter_complex 的最终输出流标签：`[bN]`
String subtitleFilterOutLabel(int overlayCount) => '[b$overlayCount]';

String _sec(int ms) => (ms / 1000).toStringAsFixed(3);
