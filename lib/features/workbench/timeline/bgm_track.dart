import 'dart:math' as math;

import '../../../core/audio/bgm_plan.dart';
import '../../../core/models/semantic_unit.dart';

/// 全片打平之后的一个视觉镜头：它在哪个单元里、是第几个、时间范围多少。
///
/// 配乐按**全片连续编号**的镜头下标存（见 [BgmSegment]），而 units 是两层
/// 嵌套结构，两边要来回换算，因此把这层换算收在一处。
class FlatShot {
  final int unitIndex;
  final int shotIndex;
  final int startMs;
  final int endMs;

  const FlatShot({
    required this.unitIndex,
    required this.shotIndex,
    required this.startMs,
    required this.endMs,
  });
}

/// 把两层结构打平成一串镜头，跨单元连续编号
List<FlatShot> flattenShots(List<SemanticUnit> units) => List.unmodifiable([
      for (var u = 0; u < units.length; u++)
        for (var s = 0; s < units[u].shots.length; s++)
          FlatShot(
            unitIndex: u,
            shotIndex: s,
            startMs: units[u].shots[s].startMs,
            endMs: units[u].shots[s].endMs,
          ),
    ]);

/// 连续台词语义单元区间 `[from, to]` 的总时长（毫秒）。
///
/// 越界下标夹住而不是抛异常：方案是存在盘上的，用户改完切分回来时下标可能
/// 已经指不到东西了，为此崩掉整个时间线不值得。
int unitRangeMs(List<SemanticUnit> units, {required int from, required int to}) {
  if (units.isEmpty) return 0;
  final lo = math.max(0, math.min(from, to));
  final hi = math.min(units.length - 1, math.max(from, to));
  if (lo > hi) return 0;
  return units[hi].endMs - units[lo].startMs;
}

/// 一段配乐在时间轴上占的范围，供绘制使用
class BgmSpan {
  final BgmSegment segment;
  final int startMs;
  final int endMs;

  const BgmSpan(
      {required this.segment, required this.startMs, required this.endMs});
}

/// 把配乐方案摊成时间轴上的若干段。
///
/// **配乐按台词语义单元对齐**（见 [BgmSegment.startUnit]）：整体替换之后
/// 单元还在、镜头没了，按镜头记的区间那一刻就悬空了。
///
/// 起点已经指不到任何单元的段直接跳过：用户删掉单元之后，旧方案会指向不存在
/// 的下标——画一段悬空的配乐比不画更让人困惑。尾端越界则夹到最后一个单元
/// （起点还在，说明这段配乐仍然有意义，只是变短了）。
List<BgmSpan> bgmSpans(BgmPlan plan, List<SemanticUnit> units) {
  if (units.isEmpty) return const [];
  return List.unmodifiable([
    for (final s in plan.segments)
      if (s.startUnit >= 0 && s.startUnit < units.length)
        BgmSpan(
          segment: s,
          startMs: units[s.startUnit].startMs,
          endMs: units[math.min(s.endUnit, units.length - 1)].endMs,
        ),
  ]);
}

/// 某个时刻落在第几个台词语义单元上。
///
/// 落在所有单元之前返回 0、之后返回最后一个：用户框选时手会滑出片尾，
/// 这时该夹到最后一个单元，而不是让选区突然消失。没有单元时返回 null。
int? unitIndexAtMs(List<SemanticUnit> units, int ms) {
  if (units.isEmpty) return null;
  for (var i = 0; i < units.length; i++) {
    if (ms < units[i].endMs) return i;
  }
  return units.length - 1;
}
