import 'package:flutter/foundation.dart';

import '../replacement/replacement_plan.dart';

/// 一个视觉镜头的坐标。
@immutable
class ShotRef {
  final int unitIndex;
  final int shotIndex;

  const ShotRef(this.unitIndex, this.shotIndex);

  @override
  bool operator ==(Object other) =>
      other is ShotRef &&
      other.unitIndex == unitIndex &&
      other.shotIndex == shotIndex;

  @override
  int get hashCode => Object.hash(unitIndex, shotIndex);

  @override
  String toString() => 'S${shotIndex + 1}（U${unitIndex + 1}）';
}

/// **挑过替换素材的单元与镜头，切分就钉死了。**
///
/// 为什么必须钉死：替换方案是按**下标**记的（单元第几个、镜头第几个）。
/// 切一刀、并一次，下标全变，原来记在 S6 上的素材就跑到别的镜头上去了——
/// 用户看到的是「我明明给这个镜头挑的素材，怎么跑到那个镜头上了」。改边界
/// 更隐蔽：镜头从 2.9 秒改成 4 秒，那条 5.5 秒的素材就得按新倍率重新变速，
/// 已经渲染好的切片全作废，而用户完全没有被告知。
///
/// 所以规则是：**给它挑过素材，它就不能再被切分、合并、改边界**。想改，
/// 先把素材移除——这一步是用户自己的决定，不是软件替他做的。
///
/// 判定看的是「有没有候选」，不是「有没有设预览」，也不看当前是哪种替换
/// 模式：候选数据只要还在盘上，切回那个模式就又生效了，下标照样会错位。
@immutable
class EditLocks {
  /// 整段被换掉的单元。它内部的镜头在成片里已经不存在了，一并钉死
  final Set<int> units;

  /// 单独挑过素材的镜头
  final Set<ShotRef> shots;

  const EditLocks({this.units = const {}, this.shots = const {}});

  static const none = EditLocks();

  static EditLocks of(List<UnitReplacement> replacements) {
    final units = <int>{};
    final shots = <ShotRef>{};
    for (var u = 0; u < replacements.length; u++) {
      final replacement = replacements[u];
      if (replacement.wholeCandidateIds.isNotEmpty) units.add(u);
      for (final entry in replacement.shotCandidateIds.entries) {
        if (entry.value.isNotEmpty) shots.add(ShotRef(u, entry.key));
      }
    }
    return EditLocks(units: Set.unmodifiable(units), shots: Set.unmodifiable(shots));
  }

  bool get isEmpty => units.isEmpty && shots.isEmpty;

  /// 这个单元被整体替换了吗
  bool isUnitLocked(int unitIndex) => units.contains(unitIndex);

  /// 这个镜头动不了吗。整段被换掉时里面的每个镜头都动不了
  bool isShotLocked(int unitIndex, int shotIndex) =>
      units.contains(unitIndex) || shots.contains(ShotRef(unitIndex, shotIndex));

  /// 这个单元里有没有任何钉死的东西。**切分/合并整个单元要看它**：
  /// 单元一拆两半，里面的镜头下标全变，钉在 S6 上的素材就错位了
  bool unitHasAnyLock(int unitIndex) =>
      units.contains(unitIndex) ||
      shots.any((s) => s.unitIndex == unitIndex);

  /// 这个单元里被钉死的镜头（升序），用于给用户点名
  List<int> lockedShotsIn(int unitIndex) => [
        for (final s in shots)
          if (s.unitIndex == unitIndex) s.shotIndex,
      ]..sort();

  @override
  bool operator ==(Object other) =>
      other is EditLocks &&
      setEquals(other.units, units) &&
      setEquals(other.shots, shots);

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(units),
      Object.hashAllUnordered(shots));
}

/// 拦下来时对用户说什么。**必须点名是哪个、为什么、怎么解开**——
/// 一句「无法操作」等于没说。
abstract final class LockWording {
  static String unit(int unitIndex) =>
      'U${unitIndex + 1} 已选替换素材，切分锁定。要调整请先移除它的替换素材。';

  static String shot(int unitIndex, int shotIndex) =>
      'U${unitIndex + 1} 的 S${shotIndex + 1} 已选替换素材，切分锁定。'
      '要调整请先移除它的替换素材。';

  /// 整个单元的结构要动，但里面有挑过素材的镜头
  static String shotsInUnit(int unitIndex, List<int> shotIndexes) {
    final names = shotIndexes.map((s) => 'S${s + 1}').join('、');
    return 'U${unitIndex + 1} 的 $names 已选替换素材，'
        '改动切分会让素材错位。要调整请先移除它们的替换素材。';
  }

  /// 时间线上那个小锁的提示语
  static const tooltip = '已选替换素材，切分锁定';
}
