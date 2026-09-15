import '../models/tag_trace.dart';
import '../time/timecode.dart';
import 'shot_boundary_detector.dart';

/// 把切点的判定明细按**帧对齐后**的毫秒重新索引。
///
/// 为什么非要这一步：切点是检出来的原始毫秒（`3435`），而镜头边界一律吸到
/// 帧上（`3433`）——两条线（全片分析、底片切分）都这么做。拿对齐后的
/// `shot.startMs` 去查原始键，绝大多数查不中，于是「这一刀是怎么定出来的」
/// 大面积缺失：属性面板里那一栏点开是空的。
///
/// **缺了不报错**，所以一直没人发现（2026-09-15 给底片切分补这一项时，
/// 量出 7 镜只贴上 2 条，才顺藤摸到全片那条线也一样）。
Map<int, BoundaryTrace> boundaryTracesByFrame(
  Map<int, ShotBoundaryCandidate> details,
  double fps,
) =>
    {
      for (final c in details.values)
        alignToFrame(c.ms, fps): BoundaryTrace(
          sceneScore: c.sceneScore,
          histDistance: c.histDistance,
          // 直接确认 / 灰区经画面复核保留——事后回看这一刀的依据
          decision: c.isConfirmed ? 'confirmed' : 'reviewed',
        ),
    };
