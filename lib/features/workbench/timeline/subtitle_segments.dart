/// 字幕轨上的**分段**：一句一段，各自能拖。
///
/// 用户 2026-09-11：「改成多段的，就像 S1、S2 一样并列放在上面就好，
/// 而且这个地方完全可以拖动……它们不能重叠，可以挨在一起，也可以中间留出
/// 空出来的地方。」
///
/// **窄的时候不展开**：一句字幕常常只有半秒，在没放大的视图里就是几个像素，
/// 十几个小块排在一起是一条噪点。所以最窄的那一段够宽才展开成多段，
/// 否则维持原样（整镜一块 + 数字角标），双击进弹窗改
/// （用户原话：「缩小的时候，画面和现在一样」）。
///
/// 这里只管**像素与命中**，不碰数据：改时间的规则在
/// `core/subtitle/subtitle_edit.dart`，界面和时间线共用那一套。
library;

import '../../../core/subtitle/subtitle_overlay.dart';

/// 一段字幕在轨上占的像素区间
class SubtitleSegmentBox {
  /// 这是这一镜的第几段
  final int index;
  final double left;
  final double right;

  const SubtitleSegmentBox(
      {required this.index, required this.left, required this.right});

  double get width => right - left;

  @override
  bool operator ==(Object other) =>
      other is SubtitleSegmentBox &&
      other.index == index &&
      other.left == left &&
      other.right == right;

  @override
  int get hashCode => Object.hash(index, left, right);

  @override
  String toString() => 'Seg($index: $left~$right)';
}

/// 展开成多段所需的最小段宽。再窄就抓不住，也写不下任何字
const double subtitleSegmentMinPx = 12;

/// 手柄的命中半径。与配乐段同一个数——同一条时间线上两种手柄
/// 手感不一样，人会以为其中一个坏了
const double subtitleEdgeHitPx = 6;

/// 这一镜的各段在轨上的位置。
///
/// 字幕的时间是**相对这一镜开头**的，而这一镜在轨上占 [blockLeft]~[blockRight]
/// ——镜头替换是变速铺满原坑位、时长不变，所以这一段线性映射成立。
List<SubtitleSegmentBox> subtitleSegmentBoxes({
  required List<SubtitleLine> lines,
  required int slotDurationMs,
  required double blockLeft,
  required double blockRight,
}) {
  if (slotDurationMs <= 0 || blockRight <= blockLeft) return const [];
  final scale = (blockRight - blockLeft) / slotDurationMs;
  return [
    for (var i = 0; i < lines.length; i++)
      SubtitleSegmentBox(
        index: i,
        left: blockLeft + lines[i].startMs * scale,
        right: blockLeft + lines[i].endMs * scale,
      ),
  ];
}

/// 够不够宽展开成多段：**最窄的那一段**说了算。
///
/// 拿平均宽或块体宽判的话，一段 3px 的碎片会混在几个大块之间——那种东西
/// 既抓不住也看不懂
bool subtitleSegmentsFit(List<SubtitleSegmentBox> boxes) {
  if (boxes.isEmpty) return false;
  for (final box in boxes) {
    if (box.width < subtitleSegmentMinPx) return false;
  }
  return true;
}

/// 拖动抓住的是哪一头
enum SubtitleGrab {
  /// 左边缘：改起点
  start,

  /// 右边缘：改终点
  end,

  /// 中间：整段平移，长度不变
  move,
}

/// 光标落在哪一段的什么位置上。都没落上返回 null。
///
/// **段很窄时两个手柄会重叠**：那时按中点劈开，左半边算左、右半边算右——
/// 和配乐段同一套处置（见 [bgmEdgeAt]）。那种宽度下没有「中间」可言
({int index, SubtitleGrab grab})? subtitleGrabAt({
  required double dx,
  required List<SubtitleSegmentBox> boxes,
}) {
  for (final box in boxes) {
    if (dx < box.left - subtitleEdgeHitPx ||
        dx > box.right + subtitleEdgeHitPx) {
      continue;
    }
    if (box.width <= subtitleEdgeHitPx * 2) {
      return (
        index: box.index,
        grab: dx < (box.left + box.right) / 2
            ? SubtitleGrab.start
            : SubtitleGrab.end
      );
    }
    if (dx <= box.left + subtitleEdgeHitPx) {
      return (index: box.index, grab: SubtitleGrab.start);
    }
    if (dx >= box.right - subtitleEdgeHitPx) {
      return (index: box.index, grab: SubtitleGrab.end);
    }
    return (index: box.index, grab: SubtitleGrab.move);
  }
  return null;
}

/// 拖了 [deltaPx] 相当于多少毫秒。块体宽 0 时返回 0——不能除以零，
/// 也不该让一个看不见的块产生位移
int subtitleDeltaMs({
  required double deltaPx,
  required int slotDurationMs,
  required double blockLeft,
  required double blockRight,
}) {
  final width = blockRight - blockLeft;
  if (width <= 0 || slotDurationMs <= 0) return 0;
  return (deltaPx / width * slotDurationMs).round();
}
