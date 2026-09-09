import '../audio/bgm_plan.dart';

/// 删掉一个单元之后，配乐区间跟着收缩。
///
/// 这个文件曾经管着四份「按下标记」的数据（替换方案、配乐、配音、手改
/// 字幕），删一个单元就要一份一份地搬——半年里漏搬过三次，每次都是
/// 「不报错，只有把片子导出来看一遍才发现」。
///
/// 现在只剩配乐：别的都按单元自己的身份记（[SemanticUnit.uid]），
/// 删一个单元只是「这个身份没了」，剩下的一份都不用动。配乐记的是**区间**
/// （哪几段连着铺一首曲子），删掉中间一段会改变「这一段盖住谁」，
/// 那是要重新算的。

/// 配乐按分子区间记（[BgmSegment.startUnit] ~ [BgmSegment.endUnit]），
/// 删了一个分子之后区间要跟着收缩或前移。
///
/// 区间里只剩这一个分子时整段删掉——留一段盖着空气的配乐，导出时会按一个
/// 不存在的范围去铺，而界面上还画着它。
BgmPlan shiftBgmAfterRemoval(BgmPlan plan, {required int removed}) {
  final kept = <BgmSegment>[];
  for (final segment in plan.segments) {
    if (removed > segment.endUnit) {
      kept.add(segment); // 删的在区间后面，不受影响
      continue;
    }
    if (removed < segment.startUnit) {
      kept.add(segment.copyWith(
          startUnit: segment.startUnit - 1, endUnit: segment.endUnit - 1));
      continue;
    }
    // 删的就在区间里
    if (segment.startUnit == segment.endUnit) continue; // 只剩它，整段没了
    kept.add(segment.copyWith(endUnit: segment.endUnit - 1));
  }
  return BgmPlan(kept);
}
