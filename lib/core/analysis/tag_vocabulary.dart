import '../miaoa/miaoa_tag_service.dart';

/// 按标签组 id 取受控词表（打标时 AI 只允许从中选词，不许自由发挥）。
///
/// 抽象出接口而不是让管线直接依赖 [MiaoaTagService]：一是单测不必碰真实
/// CLI，二是词表的来源（miaoa / 本地缓存 / 将来的其他标签体系）可以替换。
abstract class TagVocabularySource {
  /// 返回该标签组内的标签名。组内没有标签时返回空列表（不是错误）。
  Future<List<String>> vocabularyOf(int groupId);
}

/// miaoa 实现：标签组内的标签名即受控词表
class MiaoaTagVocabularySource implements TagVocabularySource {
  final MiaoaTagService service;

  const MiaoaTagVocabularySource(this.service);

  /// 失败原样抛出（[MiaoaException] 等），由调用方决定降级策略。
  /// 在这里吞成空词表会让「拉不到标签」和「组里本来就没标签」无法区分。
  @override
  Future<List<String>> vocabularyOf(int groupId) async {
    final tags = await service.listTags(groupId);
    return List.unmodifiable(tags.map((t) => t.name));
  }
}
