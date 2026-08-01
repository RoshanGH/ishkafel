import '../../../core/miaoa/miaoa_tag_service.dart';

/// 一条搜索结果：命中的标签组，以及**它为什么被搜出来**
class TagGroupHit {
  final TagGroup group;

  /// 因为这些组内标签命中而被带出来；组名直接命中时为空
  final List<String> matchedTags;

  const TagGroupHit({required this.group, this.matchedTags = const []});

  bool get matchedByName => matchedTags.isEmpty;
}

/// 按关键词搜标签组。
///
/// 同时匹配**组名**与**组内标签名**：租户里有 127 个组、2461 个标签，用户
/// 往往记得住某个标签叫什么、却记不住它归在哪个组。只搜组名等于让他继续
/// 一个个翻。
///
/// 全部在本地做，不走 CLI 的 `--keyword`：标签组连同标签一次拉回来才 210KB，
/// 本地过滤是真正的零延迟；每敲一个字起一次子进程 + 网络往返反而会卡顿，
/// 还得处理防抖与返回乱序。
List<TagGroupHit> searchTagGroups(List<TagGroup> groups, String keyword) {
  final key = keyword.trim().toLowerCase();
  if (key.isEmpty) {
    return List.unmodifiable([for (final g in groups) TagGroupHit(group: g)]);
  }

  final byName = <TagGroupHit>[];
  final byTag = <TagGroupHit>[];
  for (final g in groups) {
    if (g.name.toLowerCase().contains(key)) {
      byName.add(TagGroupHit(group: g));
      continue;
    }
    final matched = [
      for (final t in g.tags)
        if (t.toLowerCase().contains(key)) t,
    ];
    if (matched.isNotEmpty) {
      byTag.add(TagGroupHit(group: g, matchedTags: List.unmodifiable(matched)));
    }
  }
  // 组名直接命中更贴近用户意图，排在标签命中之前；同类之间保持原有顺序
  return List.unmodifiable([...byName, ...byTag]);
}
