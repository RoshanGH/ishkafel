import '../analysis/providers.dart' show AsrSentence;

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

/// 一张渲染好的字幕图和它的显示区间（切片输出时间轴）
class SubtitleOverlayImage {
  final String pngPath;
  final int startMs;
  final int endMs;

  const SubtitleOverlayImage(
      {required this.pngPath, required this.startMs, required this.endMs});
}

/// 裁出坑位 [slotStartMs, slotEndMs) 内要显示的字幕行。
///
/// 跨越坑位边界的句子只显示相交的那一段——出坑的部分由相邻原片镜头自带的
/// 字幕接手，同一时刻两边显示的是同一句话，内容是连续的。
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
    lines.add(SubtitleLine(
        startMs: start - slotStartMs, endMs: end - slotStartMs, text: text));
  }
  return List.unmodifiable(lines);
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
    parts.write(";[b$i][${i + 1}:v]overlay=0:0:"
        "enable='between(t,$from,$to)'[b${i + 1}]");
  }
  return parts.toString();
}

/// filter_complex 的最终输出流标签：`[bN]`
String subtitleFilterOutLabel(int overlayCount) => '[b$overlayCount]';

String _sec(int ms) => (ms / 1000).toStringAsFixed(3);
