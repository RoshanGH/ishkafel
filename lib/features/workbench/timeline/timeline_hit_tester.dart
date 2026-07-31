import 'package:flutter/material.dart' show Offset;
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';

/// 时间线命中结果基类（sealed 以强制完整分支处理）
sealed class TimelineHit {
  const TimelineHit();
}

/// 单元边界命中（拖大边界操作）
final class UnitBoundaryHit extends TimelineHit {
  final int leftUnitIndex;

  const UnitBoundaryHit({required this.leftUnitIndex});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnitBoundaryHit && runtimeType == other.runtimeType && leftUnitIndex == other.leftUnitIndex;

  @override
  int get hashCode => leftUnitIndex.hashCode;
}

/// 镜头边界命中（单元内部镜头间边界）
final class ShotBoundaryHit extends TimelineHit {
  final int unitIndex;
  final int leftShotIndex;

  const ShotBoundaryHit({required this.unitIndex, required this.leftShotIndex});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShotBoundaryHit &&
          runtimeType == other.runtimeType &&
          unitIndex == other.unitIndex &&
          leftShotIndex == other.leftShotIndex;

  @override
  int get hashCode => Object.hash(unitIndex, leftShotIndex);
}

/// 单元块体命中（点选单元）
final class UnitBlockHit extends TimelineHit {
  final int unitIndex;

  const UnitBlockHit({required this.unitIndex});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnitBlockHit && runtimeType == other.runtimeType && unitIndex == other.unitIndex;

  @override
  int get hashCode => unitIndex.hashCode;
}

/// 镜头块体命中
final class ShotBlockHit extends TimelineHit {
  final int unitIndex;
  final int shotIndex;

  const ShotBlockHit({required this.unitIndex, required this.shotIndex});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShotBlockHit &&
          runtimeType == other.runtimeType &&
          unitIndex == other.unitIndex &&
          shotIndex == other.shotIndex;

  @override
  int get hashCode => Object.hash(unitIndex, shotIndex);
}

/// 刻度轨命中（寻轨操作）
final class RulerHit extends TimelineHit {
  final int ms;

  const RulerHit({required this.ms});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RulerHit && runtimeType == other.runtimeType && ms == other.ms;

  @override
  int get hashCode => ms.hashCode;
}

/// 时间线轨道纵向布局常量（与 Painter 共享）
abstract final class TimelineTracks {
  static const rulerH = 20.0;
  static const unitsH = 44.0;
  static const shotsH = 26.0;
  static const thumbsH = 52.0;
  static const waveH = 34.0;
  static const gap = 4.0;

  /// 每条轨上方的标题条高度。轨道标题同时承担操作说明的职责
  /// （「拖大边界调整」/「限制在所属单元内」），对理解两层嵌套关系很关键。
  static const labelH = 14.0;

  /// 刻度轨顶部
  static double get rulerTop => 0;

  /// 刻度轨底部
  static double get rulerBottom => rulerTop + rulerH;

  /// 单元轨标题条顶部
  static double get unitsLabelTop => rulerBottom + gap;

  /// 单元轨顶部
  static double get unitsTop => unitsLabelTop + labelH;

  /// 单元轨底部
  static double get unitsBottom => unitsTop + unitsH;

  /// 镜头轨标题条顶部
  static double get shotsLabelTop => unitsBottom + gap;

  /// 镜头轨顶部
  static double get shotsTop => shotsLabelTop + labelH;

  /// 镜头轨底部
  static double get shotsBottom => shotsTop + shotsH;

  /// 缩图轨标题条顶部
  static double get thumbsLabelTop => shotsBottom + gap;

  /// 缩图轨顶部
  static double get thumbsTop => thumbsLabelTop + labelH;

  /// 缩图轨底部
  static double get thumbsBottom => thumbsTop + thumbsH;

  /// 波形轨标题条顶部
  static double get waveLabelTop => thumbsBottom + gap;

  /// 波形轨顶部
  static double get waveTop => waveLabelTop + labelH;

  /// 波形轨底部
  static double get waveBottom => waveTop + waveH;

  /// 四条轨（含各自标题条）的总高。
  ///
  /// 窗口太矮时最后一条会整条落在可视区外——用户既看不到波形，也看不到
  /// 为它准备的「生成中/生成失败」占位。窗口最小尺寸由它反推，见
  /// `macos/Runner/MainFlutterWindow.swift` 与
  /// `test/features/workbench/timeline/timeline_tracks_layout_test.dart`。
  static double get totalHeight => waveBottom;
}

/// 时间线命中判定器（纯函数，静态方法）
class TimelineHitTester {
  /// 边界容差上限（像素）：宽块体上 ±6px 范围内视为边界命中
  static const boundaryTolerancePx = 6.0;

  /// 块体窄于该宽度时（三分之一容差已不足 1px）彻底放弃其两侧的边界命中
  static const minBlockWidthForBoundaryPx = 3.0;

  /// 相邻两块之间那条边界的命中容差：取 [boundaryTolerancePx] 与"较窄一侧
  /// 块宽的三分之一"中的较小者。
  ///
  /// 固定 ±6px 会让窄块体（fit 缩放下 96 秒片长里 1.2 秒的镜头只有约 1.2px
  /// 宽，很常见）两侧的容差区把整个块体盖住：块体分支永远进不去，该镜头
  /// 在时间线上既选不中、也调不了右边界，用户只能靠放大缩放绕开。容差不
  /// 超过块宽三分之一后，任意宽度下块体的"中间三分之一"必定留给块体本身，
  /// 「左边界 / 块体 / 右边界」三个区域都可命中。
  ///
  /// 窄到连三分之一都不足 1px 时返回 0（放弃边界命中）：此时边界手柄本就
  /// 无法用鼠标可靠命中，优先保证块体可选中——用户至少能选中它，再用检查器
  /// 的 ±1 帧步进按钮精确调整边界。
  static double boundaryToleranceFor(double leftWidthPx, double rightWidthPx) {
    final narrower = leftWidthPx < rightWidthPx ? leftWidthPx : rightWidthPx;
    if (narrower < minBlockWidthForBoundaryPx) return 0;
    final third = narrower / 3;
    return third < boundaryTolerancePx ? third : boundaryTolerancePx;
  }

  /// 命中测试
  ///
  /// 优先级：边界手柄（±6px）> 块体
  ///
  /// 不同轨道返回不同结果：
  /// - 刻度轨：返回 [RulerHit]
  /// - 单元轨：返回 [UnitBoundaryHit] 或 [UnitBlockHit]
  /// - 镜头轨：返回 [UnitBoundaryHit]（单元交界边界属单元层）、[ShotBoundaryHit] 或 [ShotBlockHit]
  /// - 轨道外：返回 null
  static TimelineHit? hitTest(
    Offset localPos,
    List<SemanticUnit> units,
    TimelineGeometry geometry,
  ) {
    final x = localPos.dx;
    final y = localPos.dy;

    // 刻度轨：y in [0, 20]
    if (y >= TimelineTracks.rulerTop && y < TimelineTracks.rulerBottom) {
      return RulerHit(ms: geometry.pxToMs(x));
    }

    // 单元轨：y in [24, 68]
    if (y >= TimelineTracks.unitsTop && y < TimelineTracks.unitsBottom) {
      return _hitTestUnitTrack(x, units, geometry);
    }

    // 镜头轨：y in [72, 98]
    if (y >= TimelineTracks.shotsTop && y < TimelineTracks.shotsBottom) {
      return _hitTestShotTrack(x, units, geometry);
    }

    // 轨道外
    return null;
  }

  /// 单元轨命中判定
  /// 边界优先：检查是否靠近单元边界（容差随相邻两块宽度自适应）
  /// 否则检查块体
  static TimelineHit? _hitTestUnitTrack(
    double x,
    List<SemanticUnit> units,
    TimelineGeometry geometry,
  ) {
    if (units.isEmpty) return null;

    // 遍历单元边界，检查是否靠近边界（优先级高）
    for (int i = 0; i < units.length - 1; i++) {
      // 边界应该相邻（units[i].endMs == units[i+1].startMs）
      final boundaryPx = geometry.msToPx(units[i].endMs);
      final tolerance = boundaryToleranceFor(
        _widthPx(units[i].startMs, units[i].endMs, geometry),
        _widthPx(units[i + 1].startMs, units[i + 1].endMs, geometry),
      );

      if (tolerance > 0 && (x - boundaryPx).abs() <= tolerance) {
        return UnitBoundaryHit(leftUnitIndex: i);
      }
    }

    // 边界未命中，检查块体。
    //
    // 返回**列表位置**而不是 `unit.index`：上层 EditorSelection.unitIndex 被
    // 当列表下标使用（controller 直接 `_units[sel.unitIndex]`），而镜头轨那边
    // 返回的也是列表位置。两者靠 SegmentationEditOps._reindex 恒等才没出事，
    // 但任何一条产出 units 的路径忘了 reindex，点击就会选中错误的单元甚至越界。
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      final startPx = geometry.msToPx(unit.startMs);
      final endPx = geometry.msToPx(unit.endMs);

      if (x >= startPx && x < endPx) {
        return UnitBlockHit(unitIndex: i);
      }
    }

    return null;
  }

  /// 镜头轨命中判定
  ///
  /// 镜头轨上的块体就是镜头，因此先把所有单元的镜头拉平成一条块体序列，再对
  /// 每条相邻块体之间的边界按两侧块宽算容差。命中的边界若同时是单元交界，
  /// 返回 [UnitBoundaryHit]（单元边界属单元层，优先级更高）。
  ///
  /// 拉平后各边界的容差区互不重叠（每条边界最多吃掉相邻块体的三分之一，而
  /// 一个块体的左右两条边界分别只吃头尾三分之一），所以"取第一个命中"不再
  /// 存在歧义——此前固定 ±6px 时，窄块体上前一条边界的容差区会盖住后一条，
  /// 造成命中被前面的边界抢走。
  static TimelineHit? _hitTestShotTrack(
    double x,
    List<SemanticUnit> units,
    TimelineGeometry geometry,
  ) {
    if (units.isEmpty) return null;
    final blocks = _flattenShots(units, geometry);

    // 边界优先
    for (int i = 0; i < blocks.length - 1; i++) {
      final left = blocks[i];
      final right = blocks[i + 1];
      final tolerance = boundaryToleranceFor(
        left.endPx - left.startPx,
        right.endPx - right.startPx,
      );

      if (tolerance <= 0 || (x - left.endPx).abs() > tolerance) continue;

      return left.endsUnit
          ? UnitBoundaryHit(leftUnitIndex: left.unitIndex)
          : ShotBoundaryHit(
              unitIndex: left.unitIndex, leftShotIndex: left.shotIndex);
    }

    // 边界未命中，检查块体
    for (final block in blocks) {
      if (x >= block.startPx && x < block.endPx) {
        return ShotBlockHit(
            unitIndex: block.unitIndex, shotIndex: block.shotIndex);
      }
    }

    return null;
  }

  /// 把所有单元内的镜头按时间顺序拉平成镜头轨上的块体序列。
  /// [endsUnit] 标记该块体的右边界同时是单元边界。
  static List<_ShotBlock> _flattenShots(
    List<SemanticUnit> units,
    TimelineGeometry geometry,
  ) =>
      [
        for (int u = 0; u < units.length; u++)
          for (int s = 0; s < units[u].shots.length; s++)
            (
              unitIndex: u,
              shotIndex: s,
              startPx: geometry.msToPx(units[u].shots[s].startMs),
              endPx: geometry.msToPx(units[u].shots[s].endMs),
              endsUnit: s == units[u].shots.length - 1,
            ),
      ];

  static double _widthPx(int startMs, int endMs, TimelineGeometry geometry) =>
      geometry.msToPx(endMs) - geometry.msToPx(startMs);
}

/// 镜头轨上的一个块体（拉平后的镜头 + 其像素范围）
typedef _ShotBlock = ({
  int unitIndex,
  int shotIndex,
  double startPx,
  double endPx,
  bool endsUnit,
});
