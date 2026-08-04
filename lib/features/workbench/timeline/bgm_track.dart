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

/// 连续镜头区间 `[from, to]` 的总时长（毫秒）。
///
/// 越界下标夹住而不是抛异常：方案是存在盘上的，用户改完切分回来时下标可能
/// 已经指不到东西了，为此崩掉整个时间线不值得。
int shotRangeMs(List<SemanticUnit> units, {required int from, required int to}) {
  final flat = flattenShots(units);
  if (flat.isEmpty) return 0;
  final lo = math.max(0, math.min(from, to));
  final hi = math.min(flat.length - 1, math.max(from, to));
  if (lo > hi) return 0;
  return flat[hi].endMs - flat[lo].startMs;
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
/// 起点已经指不到任何镜头的段直接跳过：用户把镜头合并掉之后，旧方案会指向
/// 不存在的下标——画一段悬空的配乐比不画更让人困惑。尾端越界则夹到最后一个
/// 镜头（起点还在，说明这段配乐仍然有意义，只是变短了）。
List<BgmSpan> bgmSpans(BgmPlan plan, List<SemanticUnit> units) {
  final flat = flattenShots(units);
  if (flat.isEmpty) return const [];
  return List.unmodifiable([
    for (final s in plan.segments)
      if (s.startShot >= 0 && s.startShot < flat.length)
        BgmSpan(
          segment: s,
          startMs: flat[s.startShot].startMs,
          endMs: flat[math.min(s.endShot, flat.length - 1)].endMs,
        ),
  ]);
}
