/// 时间线上一格在哪儿。**全时间线只有这一处回答这个问题。**
///
/// 绘制、命中、徽标、播放曾经各写一份，用的都是
/// `geometry.msToPx(原片毫秒)`——而「原片时刻 → 成片时刻」这个方向是病态的：
/// `endMs` 是开区间，换算按「谁的原片区间盖住它」找，它落进的是**相邻那一段**。
/// 列表顺序和原片顺序一致时两者恰好相等，所以平时看不出来；一旦调过序
/// （或手加的单元被拖到最前），最后那一格的右边界会被算成别人的起点，
/// 区间左右翻转——画不出来、点不中、双击播不了。
///
/// 详见 `docs/2026-09-08-成片时间轴重构-TRD.md` 二、2.2。
library;

import '../../../core/models/semantic_unit.dart';
import 'timeline_geometry.dart';



/// 第 [listIndex] 个单元在成片上的左右像素
(double, double) unitPx(
    int listIndex, List<SemanticUnit> units, TimelineGeometry geometry) {
  final axis = geometry.axis;
  final unit = units[listIndex];
  if (axis == null) {
    // 没有成片轴 = 没有整体替换也没调过序，成片时间轴与原片时间轴重合
    return (
      geometry.composedMsToPx(unit.startMs),
      geometry.composedMsToPx(unit.endMs)
    );
  }
  final start = axis.startOf(listIndex);
  return (
    geometry.composedMsToPx(start),
    geometry.composedMsToPx(start + axis.durationOf(listIndex))
  );
}

/// 第 [unitIndex] 个单元里第 [shotIndex] 镜在成片上的左右像素。
///
/// 整体替换的单元里镜头在成片中已经不存在，这时退回按原片位置画——
/// 调用方本来就会先判 `isReplaced` 走「整段已替换」那一块
(double, double) shotPx(int unitIndex, int shotIndex,
    List<SemanticUnit> units, TimelineGeometry geometry) {
  final axis = geometry.axis;
  final a = axis?.composedShotStart(unitIndex, shotIndex);
  final b = axis?.composedShotEnd(unitIndex, shotIndex);
  if (a == null || b == null) {
    final shot = units[unitIndex].shots[shotIndex];
    return (
      geometry.composedMsToPx(shot.startMs),
      geometry.composedMsToPx(shot.endMs)
    );
  }
  return (geometry.composedMsToPx(a), geometry.composedMsToPx(b));
}
