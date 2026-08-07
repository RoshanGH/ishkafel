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

/// 一个标签命中了本项目**多少比例**的素材，就算「用了等于没筛」。
///
/// 取四分之一。别的标签通常只占百分之几，一个占到四分之一的标签在并集里
/// 就是压倒性的，切哪个镜头搜出来的都是它。这个数字是拿两个项目的真实数据
/// 卡出来的，两边都必须成立：
/// - 项目 104（6012 条）：实拍 5437（90%）、常规清洁 1947（32%）要剔；
///   灶台 352（5.9%）、厨房情景 256（4.3%）要留
/// - 项目 146（788 条）：常规清洁 501（64%）要剔；实拍 113（14%）、
///   电饭煲表面 65（8.3%）要留
const double _broadCoverage = 0.25;

/// 把没有区分度的标签剔出检索键。
///
/// **为什么必须做**：按标签检索是「满足其一」，求的是并集。真机上「实拍」在
/// 6012 条的项目里单独就命中 5437 条——等于全部素材。于是不管另外几个标签是
/// 什么，并集永远是同一批，**51 个镜头搜出来的东西一模一样**。
///
/// 两类要剔：
/// - **0 条的**：对并集毫无贡献，纯噪音
/// - **几乎等于全项目的**：它一个人就把并集撑满，别的标签全被淹没
///
/// **判宽泛要用项目总数当分母，不能拿标签之间互相比**。早先的写法是把命中数
/// 从大到小排开找最大的那道断层，断层之上全剔——在大项目里碰巧管用，到了
/// 788 条的小项目就翻车：那里的命中数是 501/113/65/13，最大断层落在
/// 65→13（5 倍），于是「电饭煲表面」「冰箱玻璃板」这些真正有区分度的标签
/// 全被当成宽泛剔掉，每个镜头最后都只剩「厨房情景」一个标签——切 S1/S2/S3
/// 搜的是同一个查询，用户看到的就是「筛选条件根本没变」。
///
/// [libraryTotal] 是这个项目的分镜总数；为 null（数不出来）时**不做宽泛剔除**
/// ——不确定时不做减法。数不出条数的标签同样保留。全被剔光时退回原样：
/// 搜得宽也好过搜不出来。
TagQueryPlan narrowTagQuery({
  required List<TagHit> hits,
  int? libraryTotal,
}) {
  if (hits.isEmpty) return const TagQueryPlan(tagIds: []);

  final all = [for (final h in hits) h.tagId];
  final broadAbove = libraryTotal != null && libraryTotal > 0
      ? libraryTotal * _broadCoverage
      : null;

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
    if (broadAbove != null && count >= broadAbove) {
      droppedBroad.add(h.name);
      continue;
    }
    kept.add(h.tagId);
  }

  // 一个都不剩：这一层的标签在本项目下要么是 0 条、要么个个都覆盖过大。
  // 把宽泛的那几个放回来，让用户至少看到点东西，同时不再声称「已排除某某」；
  // 0 条的不放回——它对「满足其一」的并集一条都贡献不了，放回来纯属噪音。
  if (kept.isEmpty) {
    final broadBack = [
      for (final h in hits)
        if (h.count != 0) h.tagId,
    ];
    if (broadBack.isEmpty) {
      // 全是 0 条：连「已排除」都无从说起，原样退回
      return TagQueryPlan(tagIds: List.unmodifiable(all), fellBack: true);
    }
    return TagQueryPlan(
      tagIds: List.unmodifiable(broadBack),
      droppedEmpty: List.unmodifiable(droppedEmpty),
      fellBack: true,
    );
  }
  return TagQueryPlan(
    tagIds: List.unmodifiable(kept),
    droppedEmpty: List.unmodifiable(droppedEmpty),
    droppedBroad: List.unmodifiable(droppedBroad),
  );
}
