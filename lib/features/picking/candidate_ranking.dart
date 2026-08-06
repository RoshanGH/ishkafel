import 'candidate_search_controller.dart';

/// 候选素材按「跟原片这一段有多像」排序。
///
/// 素材库按「任一标签命中」检索：一个单元有四个标签时，只沾上其中一个的素材
/// 也会进来。而 miaoa 返回的顺序大致是入库时间倒序——第一页看到的于是变成
/// 「最近入库的沾边素材」，而不是「最像的那些」。挑素材本来就是扫第一页就定
/// 的活，排序不对，后面所有功能都白搭。
///
/// 只用**标签重合度**排：它在结果到手的那一刻就能算，不必等 ffprobe。时长差
/// 是探测出来的，用它排会让列表在探测回来时整个跳一遍——用户刚看到的那条就
/// 找不着了。时长差仍然显示，只是不参与排序。
class CandidateRanking {
  CandidateRanking._();

  /// 这条素材命中了**哪几个**检索标签。
  ///
  /// 按检索标签的顺序给，不是素材标签的顺序——用户是照着自己选的那几个标签
  /// 在看列表。只说「命中 2 个」判断不了这条到底像不像：命中的是「灶台」
  /// 还是「实拍」，差别很大。
  static List<String> matchedTags({
    required Iterable<String> materialTags,
    required Iterable<String> queryTags,
  }) {
    final has = materialTags.toSet();
    final seen = <String>{};
    return List.unmodifiable([
      for (final tag in queryTags)
        if (has.contains(tag) && seen.add(tag)) tag,
    ]);
  }

  /// 这条素材命中了几个检索标签。与 [matchedTags] 同源，免得两处各算一遍
  /// 迟早对不上——界面上就会出现「命中 3 个」却只列出 2 个
  static int overlap(Iterable<String> materialTags, Iterable<String> queryTags) =>
      matchedTags(materialTags: materialTags, queryTags: queryTags).length;

  /// 重合度高的排前面。**稳定排序**：重合度相同的保持素材库给的原顺序——
  /// Dart 的 `List.sort` 本身不保证稳定，同分条目每次刷新都换位置，
  /// 用户会以为列表在自己乱动。
  static List<CandidateEntry> byTagOverlap(
    List<CandidateEntry> entries,
    List<String> queryTags,
  ) {
    if (queryTags.isEmpty || entries.isEmpty) return entries;
    final decorated = [
      for (var i = 0; i < entries.length; i++)
        (index: i, entry: entries[i], score: overlap(entries[i].material.tags, queryTags)),
    ]..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : a.index.compareTo(b.index);
      });
    return List.unmodifiable([for (final d in decorated) d.entry]);
  }
}
