/// 「这条候选带了检索标签里的哪几个」。
///
/// **只用于展示，不用于排序**。曾经拿它给当前页重排过，实测无效且误导：
/// S1 的六个标签「满足其一」搜出 5437 条，而这 5437 条全部来自「实拍」
/// 一个标签——它在该项目里几乎等于「所有素材」。第一页 20 条重合度全是 1，
/// 排了跟没排一样，却给人「已经按相似度排过」的错觉。现在按素材库给的
/// 顺序原样展示。
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
}
