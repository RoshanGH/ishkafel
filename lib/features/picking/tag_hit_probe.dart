import '../../core/log/app_log.dart';
import '../../core/miaoa/miaoa_content_service.dart';

/// 一个标签在当前项目里有多少条素材
class TagHit {
  final String name;
  final int tagId;

  /// 命中条数；查不到（接口失败）时为 null，界面据此写「查不到」而不是「0 条」
  final int? count;

  const TagHit({required this.name, required this.tagId, required this.count});
}

/// 逐个标签数一遍：这一层的检索标签，各自在这个项目里有多少条素材。
///
/// **为什么需要它**：按标签检索是「任一命中」，返回 0 条时用户看到的只是
/// 「这个项目里没有带这些标签的素材」——但他真正要判断的是「是我标签打错了，
/// 还是素材库里这一类本来就没入库」。摊开成「促单 0 条 · 辅助卖点 4 条」，
/// 下一步该做什么就一目了然了。
///
/// 每个标签一次子进程，所以只在**结果为空、且用户主动点了**的时候才跑：
/// 四个标签就是四次调用，无脑每次检索都跟着跑一遍纯属浪费。
class TagHitProbe {
  final MiaoaContentService service;

  /// 已经数过的：(项目, 标签) → 条数。同一个单元来回切换不必重数。
  final Map<String, int?> _cache = {};

  TagHitProbe(this.service);

  Future<List<TagHit>> probe({
    required List<({String name, int id})> tags,
    List<int> projectIds = const [],
  }) async {
    final out = <TagHit>[];
    for (final tag in tags) {
      final key = '${projectIds.join(',')}#${tag.id}';
      if (_cache.containsKey(key)) {
        out.add(TagHit(name: tag.name, tagId: tag.id, count: _cache[key]));
        continue;
      }
      int? count;
      try {
        // 只要总数，不要内容——pageSize 给 1，别把二十条素材连带拉回来
        final page = await service.searchByTags(
          tagIds: [tag.id],
          projectIds: projectIds,
          pageSize: 1,
        );
        count = page.total;
      } catch (e) {
        // 一个标签数不出来不该让整份清单作废：其余标签的数字照样有用
        AppLog.warn('标签「${tag.name}」的命中数查询失败：$e');
      }
      _cache[key] = count;
      out.add(TagHit(name: tag.name, tagId: tag.id, count: count));
    }
    return List.unmodifiable(out);
  }

  /// 这个项目里一共有多少条分镜——判断标签宽不宽的分母。
  /// 一个项目只查一次，之后全命中缓存。查不到返回 null（那就不做宽泛剔除）。
  Future<int?> libraryTotal({List<int> projectIds = const []}) async {
    final key = '${projectIds.join(',')}#total';
    if (_cache.containsKey(key)) return _cache[key];
    int? total;
    try {
      total = await service.countAll(projectIds: projectIds);
    } catch (e) {
      // 数不出分母不该让检索停摆：退化成「只剔 0 条的」
      AppLog.warn('项目分镜总数查询失败：$e');
    }
    _cache[key] = total;
    return total;
  }
}
