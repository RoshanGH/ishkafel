import '../ai/tag_dimension.dart';
import '../ai/taggers.dart';
import '../analysis/tag_vocabulary.dart';
import '../models/tag_group_ref.dart';

/// 行台词打标：复用替换裂变的 U 层打标管线（同一个打标员、同一套
/// 受控词表规则），给一行台词从任务选定的标签组里挑标签。
///
/// 标签是**所有检索的公共筛选层**（设计稿）：打出来挂在行上、可改可删，
/// 找镜头面板自动预填。
class LineTagger {
  final UnitTagger tagger;
  final TagVocabularySource vocabulary;

  LineTagger({required this.tagger, required this.vocabulary});

  /// 给一行台词打标。[groups] 是任务的分子标签组（一组 = 一个维度），
  /// [constraint] 是任务级的打标约束。词表拉取失败原样抛出
  /// （MiaoaException 等，由界面翻译成动作）。
  Future<List<String>> tag({
    required String text,
    required List<TagGroupRef> groups,
    String constraint = '',
  }) async {
    if (text.trim().isEmpty || groups.isEmpty) return const [];
    final dimensions = [
      for (final g in groups)
        TagDimension(name: g.name, vocabulary: await vocabulary.vocabularyOf(g.id)),
    ];
    final result = await tagger.understand(
      transcript: text.trim(),
      dimensions: dimensions,
      constraint: constraint.trim().isEmpty ? null : constraint.trim(),
    );
    return result.tags;
  }
}
