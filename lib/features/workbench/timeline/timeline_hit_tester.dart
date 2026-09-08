import 'package:flutter/material.dart' show Offset;
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import '../../../core/editing/edit_locks.dart';

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

  /// 字幕轨。**紧挨着镜头轨**——它修饰的就是那一层，隔开了看不出对应关系。
  /// 只在被替换的镜头下面有东西，其余位置留空
  static const subsH = 22.0;

  /// 配乐轨。比镜头轨略窄——它上面只有「哪段用了哪首」，没有边界拖拽
  static const bgmH = 24.0;
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

  /// 字幕轨标题条顶部
  static double get subsLabelTop => shotsBottom + gap;

  /// 字幕轨顶部
  static double get subsTop => subsLabelTop + labelH;

  /// 字幕轨底部
  static double get subsBottom => subsTop + subsH;

  /// 点在字幕轨上了没有。
  ///
  /// 轨上画着那几段字，点下去就该选中那一镜——人才能直接去右边改。
  /// 用户原话：「能不能直接选中字幕直接改啊？」
  static bool isOnSubsTrack(double dy) => dy >= subsTop && dy < subsBottom;

  /// 配乐轨标题条顶部
  static double get bgmLabelTop => subsBottom + gap;

  /// 配乐轨顶部
  static double get bgmTop => bgmLabelTop + labelH;

  /// 配乐轨底部
  static double get bgmBottom => bgmTop + bgmH;

  /// 缩图轨标题条顶部
  static double get thumbsLabelTop => bgmBottom + gap;

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

  /// 六条轨（含各自标题条）的总高。
  ///
  /// **就是最后一条轨的底边**，不许再有第二个出处：2026-09-08 加字幕轨时
  /// 这里还按五条轨算（290），而 painter 无条件画到 330，音频波形轨整条
  /// 落在画布外；外层 SingleChildScrollView 的子高度取 max(视口高, 这个值)，
  /// 它比视口还矮时子高度就等于视口高度，**连滚都滚不下去**。
  ///
  /// 窗口最小尺寸与三栏区/时间线区的分配比例由它反推，见
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
  /// [locks] 里的单元/镜头挑过替换素材，**它们的边界不接受拖拽**（见
  /// [EditLocks]）。锁住的边界不是"点了没反应"——命中会顺延成块体命中，
  /// 于是那一段被选中，右栏立刻说明为什么动不了、怎么解开。
  static TimelineHit? hitTest(
    Offset localPos,
    List<SemanticUnit> units,
    TimelineGeometry geometry, {
    EditLocks locks = EditLocks.none,
  }) {
    final x = localPos.dx;
    final y = localPos.dy;

    // 刻度轨：y in [0, 20]
    if (y >= TimelineTracks.rulerTop && y < TimelineTracks.rulerBottom) {
      // 点刻度尺是要定位，交给播放器的必须是**成片**毫秒
      return RulerHit(ms: geometry.pxToComposedMs(x));
    }

    // 单元轨：y in [24, 68]
    if (y >= TimelineTracks.unitsTop && y < TimelineTracks.unitsBottom) {
      return _hitTestUnitTrack(x, units, geometry, locks);
    }

    // 镜头轨：y in [72, 98]
    if (y >= TimelineTracks.shotsTop && y < TimelineTracks.shotsBottom) {
      return _hitTestShotTrack(x, units, geometry, locks);
    }

    // 轨道外
    return null;
  }

  /// 第 [i] 与第 [i+1] 个单元之间那条边界能不能拖。
  /// 与 [SegmentationEditorController.moveUnitBoundary] 的判断保持一致：
  /// 这次移动会改到两侧单元的尾/首镜头，任何一处钉住就不许拖
  static bool _unitBoundaryLocked(
      int i, List<SemanticUnit> units, EditLocks locks) {
    for (final u in [i, i + 1]) {
      if (u < 0 || u >= units.length) continue;
      if (locks.isUnitLocked(u)) return true;
      final shot = u == i ? units[u].shots.length - 1 : 0;
      if (shot >= 0 && locks.isShotLocked(u, shot)) return true;
    }
    return false;
  }

  /// 单元轨命中判定
  /// 边界优先：检查是否靠近单元边界（容差随相邻两块宽度自适应）
  /// 否则检查块体
  static TimelineHit? _hitTestUnitTrack(
    double x,
    List<SemanticUnit> units,
    TimelineGeometry geometry,
    EditLocks locks,
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
        // 锁住的边界让给块体：拖不动的东西不该长出一个能拖的手柄
        if (_unitBoundaryLocked(i, units, locks)) break;
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
    EditLocks locks,
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

      if (left.endsUnit) {
        if (_unitBoundaryLocked(left.unitIndex, units, locks)) break;
        return UnitBoundaryHit(leftUnitIndex: left.unitIndex);
      }
      // 这一刀改的是两侧镜头的时长，任一侧钉住就不许拖
      if (locks.isShotLocked(left.unitIndex, left.shotIndex) ||
          locks.isShotLocked(right.unitIndex, right.shotIndex)) {
        break;
      }
      return ShotBoundaryHit(
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
