import '../models/semantic_unit.dart';
import '../models/shot.dart';
import '../replacement/replacement_plan.dart';
import '../replacement/unit_base.dart';

/// 固定底片这一下会作废什么——**点之前要说清楚**。
class PinBaseCost {
  /// 会被取消勾选的其余候选（底片只能有一张）
  final int droppedCandidates;

  /// 会被清掉的镜头级选择（镜头都换了一批，挂在旧第 N 镜上的选择无处安放）
  final int droppedShotPicks;

  const PinBaseCost(
      {required this.droppedCandidates, required this.droppedShotPicks});

  bool get isFree => droppedCandidates == 0 && droppedShotPicks == 0;
}

/// 固定底片 / 换底片的编辑操作。纯函数，绝不原地修改。
///
/// 「固定底片」是这一段从「整段换成一条素材」变成「按这条素材精修」的那一
/// 步：从此这一段的画面取自它、镜头按它切、每一镜可以各自再换素材
/// （见 `docs/superpowers/specs/2026-09-14-底片-design.md`）。
abstract final class BasePinOps {
  /// 能不能对这一段做切分。返回拦截原因，null 表示可以。
  ///
  /// **说人话、说清楚下一步做什么**——灰一个按钮却不说为什么，
  /// 用户只会反复点它
  static String? segmentBlockedReason({
    required SemanticUnit unit,
    required UnitReplacement replacement,
  }) {
    final choice = baseChoiceOf(unit: unit, replacement: replacement);
    return switch (choice) {
      NoBase() => unit.hasSource
          ? '这条任务没有原片，这一段也还没挑素材。先给它挑一条，再来切分'
          : '这一段还没挑素材。先在右边挑一条，它就是这一段的底片',
      OriginalBase() => '这一段用的是原片，分镜在分析时已经切好了。'
          '要按别的素材重新切，先把它整体替换成那条素材',
      MaterialBase() => null,
    };
  }

  /// 固定底片会作废什么。[unit] 还没切过时只会掉多余的候选
  static PinBaseCost costOf({
    required SemanticUnit unit,
    required UnitReplacement replacement,
    required int candidateId,
  }) {
    final others =
        replacement.wholeCandidateIds.where((id) => id != candidateId).length;
    final picks = replacement.shotCandidateIds.values
        .where((ids) => ids.isNotEmpty)
        .length;
    return PinBaseCost(droppedCandidates: others, droppedShotPicks: picks);
  }

  /// 把这一段的底片固定成 [candidateId]，并写入按它切出来的 [shots]。
  ///
  /// 同时把替换方案收敛成「整体替换、只选这一条」——**这是一条不变量**：
  /// 底片固定之后候选列表里要是还留着别的，成片时间轴会按别人的时长排，
  /// 而镜头是按这一条切的，整段错位。
  static (List<SemanticUnit>, List<UnitReplacement>) pin(
    List<SemanticUnit> units,
    List<UnitReplacement> replacements,
    int index, {
    required int candidateId,
    required List<Shot> shots,
  }) {
    if (index < 0 || index >= units.length) return (units, replacements);
    final nextUnits = [
      for (var i = 0; i < units.length; i++)
        if (i == index)
          units[i].copyWith(
            baseCandidateId: candidateId,
            shots: List.unmodifiable(shots),
            // 镜头是新切的，标签还没打——标成过期，重新打标会把它们捡起来
            tagsStale: true,
          )
        else
          units[i],
    ];
    return (nextUnits, _onlyThisCandidate(replacements, index, candidateId));
  }

  /// 换底片：先把旧底片切出来的镜头和挂在上面的选择全清掉。
  ///
  /// **不禁止换**——禁止了人就被锁死在第一次的选择上；但作废什么必须
  /// 在点之前说清楚（见 [costOf]）
  static (List<SemanticUnit>, List<UnitReplacement>) unpin(
    List<SemanticUnit> units,
    List<UnitReplacement> replacements,
    int index,
  ) {
    if (index < 0 || index >= units.length) return (units, replacements);
    final unit = units[index];
    if (unit.baseCandidateId == null) return (units, replacements);
    final nextUnits = [
      for (var i = 0; i < units.length; i++)
        if (i == index)
          // 用 JSON 走一遍：copyWith 的 `??` 清不掉可空字段
          SemanticUnit.fromJson({
            ...units[i].toJson(),
            'baseCandidateId': null,
            'shots': const <Map<String, dynamic>>[],
          }..remove('baseCandidateId'))
        else
          units[i],
    ];
    return (nextUnits, _clearShotPicks(replacements, index));
  }

  /// 收敛成「整体替换、只选这一条」
  static List<UnitReplacement> _onlyThisCandidate(
          List<UnitReplacement> replacements, int index, int candidateId) =>
      [
        for (var i = 0; i < replacements.length; i++)
          if (i == index)
            UnitReplacement.whole([candidateId], previewId: candidateId)
          else
            replacements[i],
      ];

  static List<UnitReplacement> _clearShotPicks(
          List<UnitReplacement> replacements, int index) =>
      [
        for (var i = 0; i < replacements.length; i++)
          if (i == index) UnitReplacement.keepOriginal() else replacements[i],
      ];
}
