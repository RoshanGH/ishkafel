import '../audio/bgm_plan.dart';
import '../audio/voice_plan.dart';
import '../replacement/replacement_plan.dart';

/// 删掉一个分子之后，把**所有按分子下标记的东西**跟着挪。
///
/// 为什么单独一个文件：删分子这件事本身很简单（列表里去掉一项），真正的
/// 风险在于旁边还有**三份**数据也是按下标记的：替换方案、配乐、配音。
/// 它们不挪不会报错，只会让成片悄悄变成另一个样子——原本挑给 U2 的素材跑到
/// U1 身上、配乐盖错段落、配音念错地方。
///
/// 这句话原本写的是「两份」，而配音是后来加的第三种，就这么漏在了外面
/// （2026-09-07 补上）。**加第四种时把它也放进这个文件**，别再散出去。
/// 挪顺序那一组对应的是 `unit_reorder.dart`。

/// 替换方案按下标记，删了一个就整体前移
List<UnitReplacement> shiftReplacementsAfterRemoval(
  List<UnitReplacement> replacements, {
  required int removed,
}) {
  if (removed < 0 || removed >= replacements.length) return replacements;
  return List.unmodifiable([...replacements]..removeAt(removed));
}

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

/// 配音按 [VoiceAssignment.unitIndex] 记，删了一个之后后面的整体前移。
///
/// **这一条是补的**：删除原本只搬了替换方案和配乐两份，而配音是后来才加的
/// 第三种按下标记的数据，漏在了外面——删掉 U2 之后，本该念 U3 的配音会跑到
/// U2 身上，不报错，只有听出来才知道。
VoicePlan shiftVoicesAfterRemoval(VoicePlan plan, {required int removed}) =>
    VoicePlan([
      for (final a in plan.assignments)
        if (a.unitIndex != removed)
          VoiceAssignment(
              unitIndex:
                  a.unitIndex > removed ? a.unitIndex - 1 : a.unitIndex,
              voice: a.voice),
    ]);
