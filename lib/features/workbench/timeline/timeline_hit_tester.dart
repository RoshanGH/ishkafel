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

  /// 刻度轨顶部
  static double get rulerTop => 0;

  /// 刻度轨底部
  static double get rulerBottom => rulerTop + rulerH;

  /// 单元轨顶部
  static double get unitsTop => rulerBottom + gap;

  /// 单元轨底部
  static double get unitsBottom => unitsTop + unitsH;

  /// 镜头轨顶部
  static double get shotsTop => unitsBottom + gap;

  /// 镜头轨底部
  static double get shotsBottom => shotsTop + shotsH;

  /// 缩图轨顶部
  static double get thumbsTop => shotsBottom + gap;

  /// 缩图轨底部
  static double get thumbsBottom => thumbsTop + thumbsH;

  /// 波形轨顶部
  static double get waveTop => thumbsBottom + gap;

  /// 波形轨底部
  static double get waveBottom => waveTop + waveH;
}

/// 时间线命中判定器（纯函数，静态方法）
class TimelineHitTester {
  /// 边界容差（像素）：±6px 范围内视为边界命中
  static const boundaryTolerancePx = 6.0;

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
  /// 边界优先：检查是否靠近单元边界（±6px）
  /// 否则检查块体
  static TimelineHit? _hitTestUnitTrack(
    double x,
    List<SemanticUnit> units,
    TimelineGeometry geometry,
  ) {
    if (units.isEmpty) return null;

    // 遍历单元边界，检查是否靠近边界（优先级高）
    for (int i = 0; i < units.length - 1; i++) {
      final currentUnit = units[i];

      // 边界应该相邻（currentUnit.endMs == nextUnit.startMs）
      final boundaryMs = currentUnit.endMs;
      final boundaryPx = geometry.msToPx(boundaryMs);

      // 检查 x 是否在边界的容差范围内
      if ((x - boundaryPx).abs() <= boundaryTolerancePx) {
        return UnitBoundaryHit(leftUnitIndex: i);
      }
    }

    // 边界未命中，检查块体
    for (final unit in units) {
      final startPx = geometry.msToPx(unit.startMs);
      final endPx = geometry.msToPx(unit.endMs);

      if (x >= startPx && x < endPx) {
        return UnitBlockHit(unitIndex: unit.index);
      }
    }

    return null;
  }

  /// 镜头轨命中判定
  /// 特殊逻辑：如果命中的边界恰好是单元边界，返回 UnitBoundaryHit（优先级更高）
  /// 否则检查镜头边界、镜头块体
  static TimelineHit? _hitTestShotTrack(
    double x,
    List<SemanticUnit> units,
    TimelineGeometry geometry,
  ) {
    if (units.isEmpty) return null;

    // 首先检查是否靠近单元边界（优先级最高）
    for (int i = 0; i < units.length - 1; i++) {
      final currentUnit = units[i];

      final boundaryMs = currentUnit.endMs;
      final boundaryPx = geometry.msToPx(boundaryMs);

      if ((x - boundaryPx).abs() <= boundaryTolerancePx) {
        return UnitBoundaryHit(leftUnitIndex: i);
      }
    }

    // 检查镜头边界（优先级次高）
    for (int unitIdx = 0; unitIdx < units.length; unitIdx++) {
      final unit = units[unitIdx];

      // 遍历该单元内的镜头边界
      for (int shotIdx = 0; shotIdx < unit.shots.length - 1; shotIdx++) {
        final currentShot = unit.shots[shotIdx];

        final boundaryMs = currentShot.endMs;
        final boundaryPx = geometry.msToPx(boundaryMs);

        if ((x - boundaryPx).abs() <= boundaryTolerancePx) {
          return ShotBoundaryHit(unitIndex: unitIdx, leftShotIndex: shotIdx);
        }
      }
    }

    // 检查镜头块体
    for (int unitIdx = 0; unitIdx < units.length; unitIdx++) {
      final unit = units[unitIdx];

      for (int shotIdx = 0; shotIdx < unit.shots.length; shotIdx++) {
        final shot = unit.shots[shotIdx];
        final startPx = geometry.msToPx(shot.startMs);
        final endPx = geometry.msToPx(shot.endMs);

        if (x >= startPx && x < endPx) {
          return ShotBlockHit(unitIndex: unitIdx, shotIndex: shotIdx);
        }
      }
    }

    return null;
  }
}
