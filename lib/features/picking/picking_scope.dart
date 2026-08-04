import 'package:flutter/foundation.dart';

import '../../core/models/tag_group_ref.dart';
import '../../core/models/tag_trace.dart';
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

  /// 画面描述检索的关键词：选中那个视觉镜头的 AI 画面描述。
  /// 台词语义单元层不做画面描述检索（见 [descriptionSupported]）。
  final String descriptionKeyword;

  /// 这个作用域支不支持「画面描述」检索。
  ///
  /// 只有镜头层支持：画面描述是打标时对**这一个镜头**生成的一句话，
  /// 拿它去搜分镜库才对得上。整体替换换的是一整句台词对应的一串镜头，
  /// 没有一句能代表它们的画面描述——早先拿台词原文去当描述搜，
  /// 搜的是「话术像不像」，而库里那一栏写的是「画面里有什么」，本就对不上。
  final bool descriptionSupported;

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
    this.descriptionSupported = false,
    required this.tagUnavailableText,
    this.tagPending = false,
  });

  /// 从当前状态推导作用域。
  ///
  /// 两层各用各的标签，不混：
  /// - **整体替换**用这个台词语义单元自己的标签（促单、主卖点解决方案…），
  ///   它们来自台词语义单元标签组。这类标签组在 miaoa 里同样挂在分镜上
  ///   （materialType=STORYBOARD），所以拿去搜分镜是对得上的。
  /// - **镜头替换**用选中那个视觉镜头自己的标签（场景、动作、镜头类别…）。
  ///
  /// 早先整体替换取的是「本单元所有镜头标签的并集」——一个单元七八个镜头
  /// 就是十几个标签，再按「任一满足」去搜，等于把半个素材库都捞回来。
  factory PickingScope.from({
    required PickingController picking,
    required TagIdResolver resolver,
    required List<TagGroupRef> shotTagGroups,
    List<TagGroupRef> unitTagGroups = const [],
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

    // 这一层的标签取自这一层自己的标签组
    final groups = perShot ? shotTagGroups : unitTagGroups;
    final names = perShot
        ? List<String>.from(unit.shots[shotIndex].tags)
        : List<String>.from(unit.tags);
    final trace = perShot ? unit.shots[shotIndex].trace : unit.trace;
    final ids = _resolveIds(
        resolver: resolver, groups: groups, names: names, trace: trace);

    return PickingScope(
      tagNames: List.unmodifiable(names),
      tagIds: List.unmodifiable(ids),
      targetDurationMs:
          perShot ? unit.shots[shotIndex].durationMs : unit.durationMs,
      descriptionKeyword: perShot ? unit.shots[shotIndex].description ?? '' : '',
      descriptionSupported: perShot,
      tagUnavailableText: _tagUnavailable(
        resolver: resolver,
        groups: groups,
        perShot: perShot,
        names: names,
        ids: ids,
      ),
      tagPending: _tagPending(resolver, groups),
    );
  }

  /// 标签名 → 标签 id，**认组**。
  ///
  /// 「促单」这个名字可以同时存在于好几个标签组里，而 id 是按组分配的。打标
  /// 时是分维度进行的（一个标签组 = 一个维度），痕迹里记着每个标签出自哪个
  /// 维度，所以这里能精确到「分子库里的那个促单」，而不是随便一个同名标签。
  ///
  /// 旧任务的痕迹里没有维度信息，退回「在这一层选的那几个组里按顺序找」。
  static List<int> _resolveIds({
    required TagIdResolver resolver,
    required List<TagGroupRef> groups,
    required List<String> names,
    required TagTrace? trace,
  }) {
    final groupIdByName = {for (final g in groups) g.name: g.id};
    // 标签名 → 它是在哪个组（维度）下打出来的
    final sourceGroup = <String, int>{};
    for (final entry in trace?.tagsByDimension.entries ?? const <MapEntry<String, List<String>>>[]) {
      final groupId = groupIdByName[entry.key];
      if (groupId == null) continue; // 这个维度的组已经从任务里去掉了
      for (final tag in entry.value) {
        sourceGroup[tag] = groupId;
      }
    }

    final ids = <int>[];
    for (final name in names) {
      final groupId = sourceGroup[name];
      final id = groupId != null
          ? resolver.idIn(name, groupId)
          : resolver.idAmong(name, [for (final g in groups) g.id]);
      if (id != null && !ids.contains(id)) ids.add(id);
    }
    return ids;
  }

  /// 有标签组、但表还没拉回来也没失败：结论未知
  static bool _tagPending(TagIdResolver resolver, List<TagGroupRef> groups) =>
      groups.isNotEmpty &&
      !resolver.loaded &&
      resolver.loadFailure == null;

  /// 五种「标签检索用不了」的处境，各自的下一步完全不同，必须分开说
  static String? _tagUnavailable({
    required TagIdResolver resolver,
    required List<TagGroupRef> groups,
    required bool perShot,
    required List<String> names,
    required List<int> ids,
  }) {
    if (groups.isEmpty) {
      return tagSearchUnavailableText(
          hasShotTagGroup: false, queryTagCount: 0, perShot: perShot);
    }
    final failure = resolver.loadFailure;
    if (failure != null) return failure;
    // 表还没到手时不能说「找不到对应项」——那是拉完之后才成立的判断，
    // 提前说出来是一条转瞬即逝的假错误
    if (!resolver.loaded) return '正在读取标签表…';
    if (names.isEmpty) {
      return tagSearchUnavailableText(
          hasShotTagGroup: true, queryTagCount: 0, perShot: perShot);
    }
    if (ids.isEmpty) {
      return '${perShot ? '这个视觉镜头' : '这个台词语义单元'}的标签在素材库里'
          '找不到对应项（标签可能已被改名或删除），无法按标签检索';
    }
    return null;
  }
}
