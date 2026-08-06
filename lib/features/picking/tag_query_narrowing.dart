import 'tag_hit_probe.dart';

/// 收紧之后的检索键，外加「去掉了什么、为什么」
class TagQueryPlan {
  /// 真正拿去检索的标签 id
  final List<int> tagIds;

  /// 因为本项目下一条素材都没有而丢掉的
  final List<String> droppedEmpty;

  /// 因为几乎命中全项目、没有区分度而丢掉的
  final List<String> droppedBroad;

  /// 收紧之后一个标签都不剩，已退回原样
  final bool fellBack;

  const TagQueryPlan({
    required this.tagIds,
    this.droppedEmpty = const [],
    this.droppedBroad = const [],
    this.fellBack = false,
  });
}

/// 判定「宽泛」的断层倍数：把各标签的命中数从大到小排开，找最大的那道坎；
/// 坎两边差到这个倍数以上，才认为上面那几个是没有区分度的。
///
/// **为什么用断层而不是「占最大值的百分比」**：后者在数值接近时会把标签全部
/// 剔光——352/280/260 这种三个都有区分度的情形，按比例判会认定它们全都
/// 「接近最大值」。断层法只在真的差出量级时才动手：5437 对 352 是 15 倍，
/// 而 300 对 280 只有 1.07 倍。
const double _gapRatio = 3.0;

/// 把没有区分度的标签剔出检索键。
///
/// **为什么必须做**：按标签检索是「满足其一」，求的是并集。真机上这个任务的
/// 51 个镜头全部带着「实拍」，而「实拍」在该项目下单独就命中 5437 条——等于
/// 全部素材。于是不管另外几个标签是什么，并集永远是同一个 5437 条，
/// **51 个镜头搜出来的东西一模一样**。用户看到的就是「标签不起作用」。
///
/// 两类要剔：
/// - **0 条的**：对并集毫无贡献，纯噪音（S1 的达人背书/大字报/剧情都是 0 条）
/// - **几乎等于全项目的**：它一个人就把并集撑满，别的标签全被淹没
///
/// 数不出条数的保留——不确定时不做减法。全被剔光时退回原样：搜得宽也好过
/// 搜不出来。
TagQueryPlan narrowTagQuery({required List<TagHit> hits}) {
  if (hits.isEmpty) return const TagQueryPlan(tagIds: []);

  final all = [for (final h in hits) h.tagId];
  final nonZero = [
    for (final h in hits)
      if (h.count != null && h.count! > 0) h.count!,
  ]..sort((a, b) => b.compareTo(a));

  // 断层之上的都算宽泛；没有断层就一个都不剔
  var broadAbove = 0;
  if (nonZero.length > 1) {
    var bestRatio = 0.0;
    for (var i = 0; i < nonZero.length - 1; i++) {
      final ratio = nonZero[i] / nonZero[i + 1];
      if (ratio > bestRatio) {
        bestRatio = ratio;
        broadAbove = ratio >= _gapRatio ? nonZero[i] : 0;
      }
    }
  }

  final kept = <int>[];
  final droppedEmpty = <String>[];
  final droppedBroad = <String>[];
  for (final h in hits) {
    final count = h.count;
    if (count == null) {
      kept.add(h.tagId);
      continue;
    }
    if (count == 0) {
      droppedEmpty.add(h.name);
      continue;
    }
    if (broadAbove > 0 && count >= broadAbove) {
      droppedBroad.add(h.name);
      continue;
    }
    kept.add(h.tagId);
  }

  // 一个都不剩：说明这一层的标签在本项目下全是 0 条。退回原样让用户至少
  // 看到点东西，同时不再声称「已排除某某」——那时并没有排除任何东西
  if (kept.isEmpty) {
    return TagQueryPlan(tagIds: List.unmodifiable(all), fellBack: true);
  }
  return TagQueryPlan(
    tagIds: List.unmodifiable(kept),
    droppedEmpty: List.unmodifiable(droppedEmpty),
    droppedBroad: List.unmodifiable(droppedBroad),
  );
}
