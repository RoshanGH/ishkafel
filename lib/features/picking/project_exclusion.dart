import '../../core/miaoa/miaoa_content_service.dart';

/// 排除掉某些项目之后的一页候选
class ExcludedCandidatePage {
  final List<CandidateMaterial> items;

  /// 服务端命中总数（**没有**扣掉被排除的——那要翻完全部才知道）
  final int total;

  /// 这次翻过的页里排掉了多少条
  final int excludedCount;

  /// 实际翻了几页。翻页是要时间的，如实说出来
  final int pagesFetched;

  const ExcludedCandidatePage({
    required this.items,
    required this.total,
    required this.excludedCount,
    required this.pagesFetched,
  });
}

/// 边搜边排除，凑够 [want] 条为止。
///
/// **为什么要翻页**：替换裂变的意义就是换掉原来那批画面，而语义检索越准，
/// 搜出来越是原项目自己拍的（跟原镜最像的当然是原片素材）。真机上一整页
/// 50 条可能全是原项目——直接过滤完返回，人拿到的是空列表，还得自己想到
/// 「那我翻一页试试」。
///
/// 但也不能一直翻：每翻一页都是一次网络往返。[maxPages] 到顶就如实返回，
/// 少了就是少了，不假装。
Future<ExcludedCandidatePage> searchExcluding({
  required Future<CandidatePage> Function(int page) fetch,
  required Set<int> exclude,
  required int want,
  int firstPage = 1,
  int maxPages = 5,
}) async {
  final kept = <CandidateMaterial>[];
  var excluded = 0;
  var pages = 0;
  var total = 0;

  for (var i = 0; i < maxPages; i++) {
    final page = await fetch(firstPage + i);
    pages++;
    total = page.total;
    for (final item in page.items) {
      if (item.projectId != null && exclude.contains(item.projectId)) {
        excluded++;
        continue;
      }
      kept.add(item);
    }
    // 没排除任何项目、或者已经够了、或者服务端也没更多了，就停
    if (exclude.isEmpty || kept.length >= want || page.items.isEmpty) break;
    if ((firstPage + i) * page.items.length >= total) break;
  }

  return ExcludedCandidatePage(
    items: List.unmodifiable(kept.take(want)),
    total: total,
    excludedCount: excluded,
    pagesFetched: pages,
  );
}
