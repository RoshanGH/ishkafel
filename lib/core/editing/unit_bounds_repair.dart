import '../models/semantic_unit.dart';

/// 把被挪错的单元起止**按它自己的视觉镜头修回来**。
///
/// 起因（2026-09-09 真机）：删掉一个手动加的台词语义单元时走的是空白任务
/// 那套 `BlankUnitOps.removeAt`，它会把所有单元的 `startMs/endMs` 重新铺成
/// 连续的一条——而单元里的视觉镜头留在原地。于是同一个单元的两层坐标各说
/// 各话：镜头轨画到别处、单元尾部空出一截、点中的和播的不是同一段。
///
/// 起因已经修掉（见 `unit_reorder.dart` 的 `removeUnitAt`），但**盘上那些
/// 已经坏掉的任务不会自己好**，而人只会看到「合并镜头之后后面缺了一块」，
/// 根本联想不到是几天前删过一个单元。所以在读档时修回来。
///
/// 修的依据是不变量：**一个单元里的视觉镜头首尾相接、正好铺满这个单元**。
/// 所以镜头首尾就是这个单元的真身。只在两件事同时成立时才动：
/// - 这个单元有镜头（手动加的单元没有镜头，它的起止本来就是排出来的）；
/// - 镜头铺出来的**长度和单元的长度一致**——只是整体平移了。长度都不一样
///   就不是这个 bug，那时不猜，原样留着（宁可显示得怪，也不能把好数据改坏）。
List<SemanticUnit> repairUnitBoundsFromShots(List<SemanticUnit> units) {
  var changed = false;
  final out = [
    for (final unit in units) () {
      final shots = unit.shots;
      if (shots.isEmpty) return unit;
      final start = shots.first.startMs;
      final end = shots.last.endMs;
      if (start == unit.startMs && end == unit.endMs) return unit;
      if (end - start != unit.endMs - unit.startMs) return unit;
      changed = true;
      return unit.copyWith(startMs: start, endMs: end);
    }(),
  ];
  return changed ? out : units;
}
