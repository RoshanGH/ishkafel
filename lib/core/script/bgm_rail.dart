import '../audio/bgm_plan.dart';
import 'script_doc.dart';

/// 配乐轨（行带左缘那条色带）的纯逻辑层。
///
/// **人的心智不是「第 6 行到第 18 行用这首」，而是「从这一句开始换歌」**
/// （用户 2026-08-21 定的）。所以这里的模型是**分界点**：整片被若干刀
/// 切成连续的段，段与段首尾相接、铺满全片，不存在空洞与重叠——
/// 一条 30 句的片子配 3 首曲子，只需要切两刀。
class BgmRailSegment {
  /// 这一段覆盖的行区间（闭区间）
  final int startLine;
  final int endLine;

  /// 这一段用的曲子；null = 这一段不要配乐
  final BgmMaterial? material;
  final double volume;

  const BgmRailSegment({
    required this.startLine,
    required this.endLine,
    required this.material,
    required this.volume,
  });

  bool get silent => material == null;

  BgmRailSegment copyWith({
    int? startLine,
    int? endLine,
    Object? material = _unset,
    double? volume,
  }) =>
      BgmRailSegment(
        startLine: startLine ?? this.startLine,
        endLine: endLine ?? this.endLine,
        material:
            identical(material, _unset) ? this.material : material as BgmMaterial?,
        volume: volume ?? this.volume,
      );

  static const _unset = Object();
}

/// 落盘的配乐段 → 铺满全片的轨段（没被覆盖的行补成「不要配乐」的段）。
///
/// [lineCount] 是脚本行数；行数为 0 时返回空轨
List<BgmRailSegment> bgmRail(List<ScriptBgmSegment> saved, int lineCount) {
  if (lineCount <= 0) return const [];
  final sorted = [...saved]..sort((a, b) => a.startLine.compareTo(b.startLine));
  final out = <BgmRailSegment>[];
  var cursor = 0;
  for (final seg in sorted) {
    final start = seg.startLine.clamp(0, lineCount - 1);
    final end = seg.endLine.clamp(start, lineCount - 1);
    if (start > cursor) {
      out.add(BgmRailSegment(
          startLine: cursor,
          endLine: start - 1,
          material: null,
          volume: BgmSegment.defaultVolume));
    }
    if (end < cursor) continue; // 与前段重叠：丢掉（落盘数据被外部改坏时）
    out.add(BgmRailSegment(
        startLine: start < cursor ? cursor : start,
        endLine: end,
        material: seg.material,
        volume: seg.volume));
    cursor = end + 1;
  }
  if (cursor <= lineCount - 1) {
    out.add(BgmRailSegment(
        startLine: cursor,
        endLine: lineCount - 1,
        material: null,
        volume: BgmSegment.defaultVolume));
  }
  return List.unmodifiable(out);
}

/// 轨段 → 落盘的配乐段（「不要配乐」的段不落盘）
List<ScriptBgmSegment> railToSegments(List<BgmRailSegment> rail) => [
      for (final s in rail)
        if (s.material != null)
          ScriptBgmSegment(
            startLine: s.startLine,
            endLine: s.endLine,
            material: s.material!,
            volume: s.volume,
          ),
    ];

/// 在第 [lineIndex] 句处**切一刀**：这一句成为新段的开头，
/// 新段先继承上一段的曲子与音量（多数时候只是换个曲子，继承省一步）。
/// 已经是段首、或越界，原样返回
List<BgmRailSegment> splitRailAt(List<BgmRailSegment> rail, int lineIndex) {
  for (var i = 0; i < rail.length; i++) {
    final s = rail[i];
    if (lineIndex <= s.startLine || lineIndex > s.endLine) continue;
    return [
      ...rail.sublist(0, i),
      s.copyWith(endLine: lineIndex - 1),
      s.copyWith(startLine: lineIndex),
      ...rail.sublist(i + 1),
    ];
  }
  return rail;
}

/// 删掉第 [segIndex] 段前面那一刀：这一段并回上一段（用上一段的曲子）
List<BgmRailSegment> mergeRailWithPrev(
    List<BgmRailSegment> rail, int segIndex) {
  if (segIndex <= 0 || segIndex >= rail.length) return rail;
  final prev = rail[segIndex - 1];
  return [
    ...rail.sublist(0, segIndex - 1),
    prev.copyWith(endLine: rail[segIndex].endLine),
    ...rail.sublist(segIndex + 1),
  ];
}

/// 把第 [segIndex] 段的开头挪到第 [newStart] 句（拖分界）。
/// 夹在「上一段至少留一句」与「本段至少留一句」之间
List<BgmRailSegment> moveRailBoundary(
    List<BgmRailSegment> rail, int segIndex, int newStart) {
  if (segIndex <= 0 || segIndex >= rail.length) return rail;
  final prev = rail[segIndex - 1];
  final cur = rail[segIndex];
  final lo = prev.startLine + 1;
  final hi = cur.endLine;
  final start = newStart.clamp(lo, hi);
  if (start == cur.startLine) return rail;
  return [
    ...rail.sublist(0, segIndex - 1),
    prev.copyWith(endLine: start - 1),
    cur.copyWith(startLine: start),
    ...rail.sublist(segIndex + 1),
  ];
}
