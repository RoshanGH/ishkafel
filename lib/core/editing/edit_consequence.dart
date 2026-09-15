import '../models/semantic_unit.dart';
import '../replacement/replacement_plan.dart';

/// 改了切分之后要不要连坐——清掉已挑好的素材、重新打标。
///
/// 这两件事都**不自动做**。用户可能只是把边界挪了一帧修个口型，画面几乎没
/// 变，标签和挑好的素材照样成立；也可能把一个单元砍掉三成，原来挑的素材完全
/// 对不上了。软件分不清这两种，所以问一句，但要把默认值调到多数情况下是对的
/// 那一边——问得对，用户一路回车就走完了。
class EditConsequence {
  /// 受影响的台词语义单元下标（升序）
  final List<int> unitIndexes;

  /// 单元数变了（拆分/合并/删除）。这种改动一定是大改动。
  final bool structural;

  /// 受影响单元里，边界移动幅度占其时长的最大比例
  final double maxChangedRatio;

  const EditConsequence({
    required this.unitIndexes,
    required this.structural,
    required this.maxChangedRatio,
  });

  /// 超过这个比例就算「改得多」。
  ///
  /// 5%：10 秒的单元挪半秒。再小的改动多半是对口型、切掉一点点静音，
  /// 打出来的标签和挑好的素材不会因此失效。
  static const double significantRatio = 0.05;

  bool get significant => structural || maxChangedRatio >= significantRatio;

  bool get clearCandidatesByDefault => significant;
  bool get retagByDefault => significant;

  /// 比较编辑前后的切分，判断要不要问、问哪几个单元。
  ///
  /// 返回 null 表示不用问：要么什么都没改，要么受影响的单元既没挑素材也没
  /// 打过标签——问「要不要清除/重打」是在问一个不存在的东西。
  static EditConsequence? evaluate({
    required List<SemanticUnit> before,
    required List<SemanticUnit> after,
    required List<UnitReplacement> replacements,
  }) {
    final structural = before.length != after.length;
    final affected = <int>[];
    var maxRatio = 0.0;

    // **按身份（uid）比，不按下标比。**
    //
    // 单元数变了不等于每个单元都变了：在末尾加一个空单元，前面那些一个字节
    // 都没动，而原来会把它们全部报成「受影响」——默认勾上「取消已挑的素材」
    // 和「重新打标」，手快点下去就是白清一遍素材、白花一次打标的钱
    // （2026-09-15 真机：加一个插入段，弹出来说「改到了 U1…等 7 个」）。
    //
    // uid 是单元的身份，拆分时左半保留、右半发新的，合并时留下前者的
    // ——拿它对得上的就逐个比，对不上的（新加的）本来就没东西可丢。
    final byUid = {
      for (final u in before)
        if (u.uid.isNotEmpty) u.uid: u,
    };
    // 老存档没发过 uid：退回原来那套「凡是有内容可丢的都问到」，
    // 宁可多问一次，也不能悄悄把东西丢了
    final canMatchByUid =
        byUid.length == before.length && after.every((u) => u.uid.isNotEmpty);

    if (structural && !canMatchByUid) {
      for (var i = 0; i < after.length; i++) {
        if (_hasSomethingToLose(after, replacements, i)) affected.add(i);
      }
    } else {
      for (var i = 0; i < after.length; i++) {
        final was = canMatchByUid
            ? byUid[after[i].uid]
            : (i < before.length ? before[i] : null);
        // 这一个是新加进来的：它自己还什么都没有，谈不上丢
        if (was == null) continue;
        final ratio = _changedRatio(was, after[i]);
        if (ratio <= 0) continue;
        if (!_hasSomethingToLose(after, replacements, i)) continue;
        affected.add(i);
        if (ratio > maxRatio) maxRatio = ratio;
      }
    }

    if (affected.isEmpty) return null;
    return EditConsequence(
      unitIndexes: affected,
      structural: structural,
      maxChangedRatio: maxRatio,
    );
  }

  /// 这个单元有没有「会被连坐的东西」：挑好的候选素材，或打过的标签
  static bool _hasSomethingToLose(
    List<SemanticUnit> units,
    List<UnitReplacement> replacements,
    int i,
  ) {
    final picked = i < replacements.length &&
        replacements[i].mode != ReplacementMode.keepOriginal;
    if (picked) return true;
    final unit = units[i];
    return unit.tags.isNotEmpty || unit.shots.any((s) => s.tags.isNotEmpty);
  }

  /// 单元边界与镜头边界一共挪了多少，折算成占该单元时长的比例。
  ///
  /// 两端的位移相加而不是取净值：把开始和结束同时右移 1 秒（整体平移）画面
  /// 是全换了的，取净值会算成 0。
  static double _changedRatio(SemanticUnit before, SemanticUnit after) {
    var moved = (after.startMs - before.startMs).abs() +
        (after.endMs - before.endMs).abs();
    if (before.shots.length != after.shots.length) {
      // 镜头增删同样是结构性改动，但只影响这一个单元
      return 1;
    }
    for (var i = 0; i < after.shots.length; i++) {
      moved += (after.shots[i].startMs - before.shots[i].startMs).abs() +
          (after.shots[i].endMs - before.shots[i].endMs).abs();
    }
    final span = before.durationMs;
    if (span <= 0) return moved > 0 ? 1 : 0;
    return moved / span;
  }

  /// 把受影响单元的替换方案清回「保留原片」。没被碰过的单元原样保留——
  /// 顺手一起清了，用户会以为软件坏了。
  List<UnitReplacement> clearCandidates(List<UnitReplacement> plan) => [
        for (var i = 0; i < plan.length; i++)
          unitIndexes.contains(i) ? UnitReplacement.keepOriginal() : plan[i],
      ];

  /// 把受影响单元（含其视觉镜头）的标签标记为过期。
  ///
  /// 标记而不是抹掉：重打是异步的，这中间把标签清空，用户会以为标签丢了。
  List<SemanticUnit> markForRetag(List<SemanticUnit> units) => [
        for (var i = 0; i < units.length; i++)
          if (unitIndexes.contains(i))
            units[i].copyWith(
              tagsStale: true,
              shots: [for (final s in units[i].shots) s.copyWith(tagsStale: true)],
            )
          else
            units[i],
      ];

  /// 合并两个单元时标签怎么算：直接用合并目标 [target] 的。
  ///
  /// 产品决策——A 合并到 B，标签就用 B 的。取并集会把两组本来互斥的描述
  /// 混在一起（「近景」+「远景」），比只保留一组更没法用。
  static SemanticUnit mergeTags({
    required SemanticUnit target,
    required SemanticUnit absorbed,
  }) =>
      target;
}
