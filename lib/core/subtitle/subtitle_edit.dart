/// 改一段字幕的时间。**属性卡里输数字、时间线上拖，都走这里。**
///
/// 两处各写一套的话，能拖出来的和能输出来的迟早不一样——而这种不一样
/// 人只有在成片里才看得见。规则是产品定的（2026-09-11）：
///
/// - **不许重叠**：两句字同时挂在画面上就是打架，这条片子是要交付的；
/// - **可以挨着**（前一段的结束 = 后一段的开始），也可以中间留空；
/// - **不许拖出这一镜**：字幕绑在被替换的那个视觉镜头上（见 [SubtitleSlot]），
///   烧的时候是烧进那一镜的切片里，出了界根本没地方烧；
/// - **不许压成 0 长**：那种段在轨上点不中，在画面上也只是一闪。
///
/// 时间一律是**相对这一镜开头**的毫秒（与 [subtitleLinesInSlot] 同一套基准）。
library;

import 'subtitle_overlay.dart';

/// 一段字幕最少多长
const int minSubtitleMs = 100;

/// 改第 [index] 段的起点
List<SubtitleLine> setSubtitleStart(
  List<SubtitleLine> lines,
  int index,
  int startMs, {
  required int slotDurationMs,
}) =>
    _retimed(lines, index, slotDurationMs, (line, lower, upper) {
      final start = startMs.clamp(lower, line.endMs - minSubtitleMs);
      return SubtitleLine(
          startMs: start, endMs: line.endMs, text: line.text);
    });

/// 改第 [index] 段的终点
List<SubtitleLine> setSubtitleEnd(
  List<SubtitleLine> lines,
  int index,
  int endMs, {
  required int slotDurationMs,
}) =>
    _retimed(lines, index, slotDurationMs, (line, lower, upper) {
      final end = endMs.clamp(line.startMs + minSubtitleMs, upper);
      return SubtitleLine(
          startMs: line.startMs, endMs: end, text: line.text);
    });

/// 整段平移 [deltaMs]。**长度一分不变**——顶到边就停住，不是压扁
List<SubtitleLine> moveSubtitle(
  List<SubtitleLine> lines,
  int index,
  int deltaMs, {
  required int slotDurationMs,
}) =>
    _retimed(lines, index, slotDurationMs, (line, lower, upper) {
      final span = line.endMs - line.startMs;
      // 夹的是起点，上界要给长度让位；空间不够时优先保住起点不越界
      final maxStart = upper - span;
      final start = maxStart < lower
          ? lower
          : (line.startMs + deltaMs).clamp(lower, maxStart);
      return SubtitleLine(
          startMs: start, endMs: start + span, text: line.text);
    });

/// 公共的三件事：下标校验、算出这一段能动的上下界、把结果放回去
List<SubtitleLine> _retimed(
  List<SubtitleLine> lines,
  int index,
  int slotDurationMs,
  SubtitleLine Function(SubtitleLine line, int lower, int upper) retime,
) {
  if (index < 0 || index >= lines.length) return lines;
  // 坑位短到放不下一段：别动它，也别抛——镜头被改短时会走到这儿
  if (slotDurationMs < minSubtitleMs) return lines;
  final lower = index == 0 ? 0 : lines[index - 1].endMs;
  final upper =
      index == lines.length - 1 ? slotDurationMs : lines[index + 1].startMs;
  // 邻段本身就越界（镜头被改短了）时，上界同样要夹住
  final safeUpper = upper > slotDurationMs ? slotDurationMs : upper;
  final next = retime(lines[index], lower, safeUpper);
  return [
    for (var i = 0; i < lines.length; i++)
      if (i == index) next else lines[i],
  ];
}
