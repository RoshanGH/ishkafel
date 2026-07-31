import 'package:flutter/foundation.dart';

import '../../core/models/tag_group_ref.dart';
import '../../core/replacement/replacement_plan.dart';
import 'picking_controller.dart';
import 'picking_messages.dart';
import 'tag_id_resolver.dart';

/// 「当前正在为谁挑候选」——整体替换时是整个台词语义单元，镜头级时是选中的
/// 那个视觉镜头。检索键（标签 / 关键词）与时长差的基准都取自这里。
///
/// 做成不可变值对象而不是散在面板里的一堆 getter：面板只管画，检索键怎么推导
/// 是可以单独测的规则（尤其是「标签为什么不可用」的几种处境）。
@immutable
class PickingScope {
  /// 作用域上的标签名（打标产出）
  final List<String> tagNames;

  /// 解析成 miaoa 标签 id 之后的检索键
  final List<int> tagIds;

  /// 目标片段时长，用于候选卡的时长差徽标
  final int targetDurationMs;

  /// 画面描述检索的默认关键词（取本单元台词——原片这一层没有 AI 画面描述）
  final String descriptionKeyword;

  /// 标签检索不可用的原因；可用时为 null
  final String? tagUnavailableText;

  /// 标签表还在拉取中——「暂时不能用」不等于「不能用」。
  /// 这一刻不该把检索方式改判成画面描述：拉完可能一切正常，
  /// 而自动切换是不可逆的（不会再切回来），用户会莫名其妙地丢掉主路径。
  final bool tagPending;

  const PickingScope({
    required this.tagNames,
    required this.tagIds,
    required this.targetDurationMs,
    required this.descriptionKeyword,
    required this.tagUnavailableText,
    this.tagPending = false,
  });

  /// 从当前状态推导作用域。
  ///
  /// 整体替换取本单元**所有视觉镜头标签的并集**：候选素材是分镜库素材，能与
  /// 之比对的只有画面层标签；台词语义层的标签属于另一套词表，拿去检索分镜
  /// 只会检索出无关素材。
  factory PickingScope.from({
    required PickingController picking,
    required TagIdResolver resolver,
    required TagGroupRef? shotTagGroup,
  }) {
    final unit = picking.currentUnit;
    if (unit == null) {
      return const PickingScope(
        tagNames: [],
        tagIds: [],
        targetDurationMs: 0,
        descriptionKeyword: '',
        tagUnavailableText: '还没有可挑选的台词语义单元',
      );
    }

    final shotIndex = picking.selectedShotIndex;
    final perShot = picking.currentMode == ReplacementMode.perShot &&
        shotIndex != null &&
        shotIndex < unit.shots.length;

    final names = perShot
        ? List<String>.from(unit.shots[shotIndex].tags)
        : _unionShotTags(picking);
    final ids = resolver.idsOf(names);

    return PickingScope(
      tagNames: List.unmodifiable(names),
      tagIds: List.unmodifiable(ids),
      targetDurationMs:
          perShot ? unit.shots[shotIndex].durationMs : unit.durationMs,
      descriptionKeyword: unit.transcript,
      tagUnavailableText: _tagUnavailable(
        resolver: resolver,
        shotTagGroup: shotTagGroup,
        names: names,
        ids: ids,
      ),
      tagPending: _tagPending(resolver, shotTagGroup),
    );
  }

  static List<String> _unionShotTags(PickingController picking) {
    final seen = <String>[];
    for (final shot in picking.currentUnit?.shots ?? const []) {
      for (final tag in shot.tags) {
        if (!seen.contains(tag)) seen.add(tag);
      }
    }
    return seen;
  }

  /// 有标签组、但表还没拉回来也没失败：结论未知
  static bool _tagPending(TagIdResolver resolver, TagGroupRef? shotTagGroup) =>
      shotTagGroup != null && !resolver.loaded && resolver.loadFailure == null;

  /// 五种「标签检索用不了」的处境，各自的下一步完全不同，必须分开说
  static String? _tagUnavailable({
    required TagIdResolver resolver,
    required TagGroupRef? shotTagGroup,
    required List<String> names,
    required List<int> ids,
  }) {
    if (shotTagGroup == null) {
      return tagSearchUnavailableText(hasShotTagGroup: false, queryTagCount: 0);
    }
    final failure = resolver.loadFailure;
    if (failure != null) return failure;
    // 表还没到手时不能说「找不到对应项」——那是拉完之后才成立的判断，
    // 提前说出来是一条转瞬即逝的假错误
    if (!resolver.loaded) return '正在读取标签表…';
    if (names.isEmpty) {
      return tagSearchUnavailableText(hasShotTagGroup: true, queryTagCount: 0);
    }
    if (ids.isEmpty) {
      return '这个视觉镜头的标签在素材库里找不到对应项（标签可能已被改名或删除），'
          '无法按标签检索。可以改用「画面描述」';
    }
    return null;
  }
}
