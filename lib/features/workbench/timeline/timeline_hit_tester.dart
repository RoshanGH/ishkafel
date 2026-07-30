import 'package:flutter/material.dart' show Offset;
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';

/// 時間線命中結果基類（sealed 以強制完整分支處理）
sealed class TimelineHit {
  const TimelineHit();
}

/// 單元邊界命中（拖大邊界操作）
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

/// 鏡頭邊界命中（單元內部鏡頭間邊界）
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

/// 單元塊體命中（點選單元）
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

/// 鏡頭塊體命中
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

/// 刻度軌命中（尋軌操作）
final class RulerHit extends TimelineHit {
  final int ms;

  const RulerHit({required this.ms});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RulerHit && runtimeType == other.runtimeType && ms == other.ms;

  @override
  int get hashCode => ms.hashCode;
}

/// 時間線軌道縱向布局常量（與 Painter 共享）
abstract final class TimelineTracks {
  static const rulerH = 20.0;
  static const unitsH = 44.0;
  static const shotsH = 26.0;
  static const thumbsH = 52.0;
  static const waveH = 34.0;
  static const gap = 4.0;

  /// 刻度軌頂部
  static double get rulerTop => 0;

  /// 刻度軌底部
  static double get rulerBottom => rulerTop + rulerH;

  /// 單元軌頂部
  static double get unitsTop => rulerBottom + gap;

  /// 單元軌底部
  static double get unitsBottom => unitsTop + unitsH;

  /// 鏡頭軌頂部
  static double get shotsTop => unitsBottom + gap;

  /// 鏡頭軌底部
  static double get shotsBottom => shotsTop + shotsH;

  /// 縮圖軌頂部
  static double get thumbsTop => shotsBottom + gap;

  /// 縮圖軌底部
  static double get thumbsBottom => thumbsTop + thumbsH;

  /// 波形軌頂部
  static double get waveTop => thumbsBottom + gap;

  /// 波形軌底部
  static double get waveBottom => waveTop + waveH;
}

/// 時間線命中判定器（純函數，靜態方法）
class TimelineHitTester {
  /// 邊界容差（像素）：±6px 範圍內視為邊界命中
  static const boundaryTolerancePx = 6.0;

  /// 命中測試
  ///
  /// 優先級：邊界手柄（±6px）> 塊體
  ///
  /// 不同軌道返回不同結果：
  /// - 刻度軌：返回 [RulerHit]
  /// - 單元軌：返回 [UnitBoundaryHit] 或 [UnitBlockHit]
  /// - 鏡頭軌：返回 [UnitBoundaryHit]（單元交界邊界屬單元層）、[ShotBoundaryHit] 或 [ShotBlockHit]
  /// - 軌道外：返回 null
  static TimelineHit? hitTest(
    Offset localPos,
    List<SemanticUnit> units,
    TimelineGeometry geometry,
  ) {
    final x = localPos.dx;
    final y = localPos.dy;

    // 刻度軌：y in [0, 20]
    if (y >= TimelineTracks.rulerTop && y < TimelineTracks.rulerBottom) {
      return RulerHit(ms: geometry.pxToMs(x));
    }

    // 單元軌：y in [24, 68]
    if (y >= TimelineTracks.unitsTop && y < TimelineTracks.unitsBottom) {
      return _hitTestUnitTrack(x, units, geometry);
    }

    // 鏡頭軌：y in [72, 98]
    if (y >= TimelineTracks.shotsTop && y < TimelineTracks.shotsBottom) {
      return _hitTestShotTrack(x, units, geometry);
    }

    // 軌道外
    return null;
  }

  /// 單元軌命中判定
  /// 邊界優先：檢查是否靠近單元邊界（±6px）
  /// 否則檢查塊體
  static TimelineHit? _hitTestUnitTrack(
    double x,
    List<SemanticUnit> units,
    TimelineGeometry geometry,
  ) {
    if (units.isEmpty) return null;

    // 遍歷單元邊界，檢查是否靠近邊界（優先級高）
    for (int i = 0; i < units.length - 1; i++) {
      final currentUnit = units[i];

      // 邊界應該相鄰（currentUnit.endMs == nextUnit.startMs）
      final boundaryMs = currentUnit.endMs;
      final boundaryPx = geometry.msToPx(boundaryMs);

      // 檢查 x 是否在邊界的容差範圍內
      if ((x - boundaryPx).abs() <= boundaryTolerancePx) {
        return UnitBoundaryHit(leftUnitIndex: i);
      }
    }

    // 邊界未命中，檢查塊體
    for (final unit in units) {
      final startPx = geometry.msToPx(unit.startMs);
      final endPx = geometry.msToPx(unit.endMs);

      if (x >= startPx && x < endPx) {
        return UnitBlockHit(unitIndex: unit.index);
      }
    }

    return null;
  }

  /// 鏡頭軌命中判定
  /// 特殊邏輯：如果命中的邊界恰好是單元邊界，返回 UnitBoundaryHit（優先級更高）
  /// 否則檢查鏡頭邊界、鏡頭塊體
  static TimelineHit? _hitTestShotTrack(
    double x,
    List<SemanticUnit> units,
    TimelineGeometry geometry,
  ) {
    if (units.isEmpty) return null;

    // 首先檢查是否靠近單元邊界（優先級最高）
    for (int i = 0; i < units.length - 1; i++) {
      final currentUnit = units[i];

      final boundaryMs = currentUnit.endMs;
      final boundaryPx = geometry.msToPx(boundaryMs);

      if ((x - boundaryPx).abs() <= boundaryTolerancePx) {
        return UnitBoundaryHit(leftUnitIndex: i);
      }
    }

    // 檢查鏡頭邊界（優先級次高）
    for (int unitIdx = 0; unitIdx < units.length; unitIdx++) {
      final unit = units[unitIdx];

      // 遍歷該單元內的鏡頭邊界
      for (int shotIdx = 0; shotIdx < unit.shots.length - 1; shotIdx++) {
        final currentShot = unit.shots[shotIdx];

        final boundaryMs = currentShot.endMs;
        final boundaryPx = geometry.msToPx(boundaryMs);

        if ((x - boundaryPx).abs() <= boundaryTolerancePx) {
          return ShotBoundaryHit(unitIndex: unitIdx, leftShotIndex: shotIdx);
        }
      }
    }

    // 檢查鏡頭塊體
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
