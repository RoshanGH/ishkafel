import '../../core/replacement/replacement_plan.dart';

/// 角标上最多显示到 99，再多折成「99+」——三位数会把小圆角标撑变形，
/// 而「到底是 120 还是 137」对用户没有任何差别
const int _badgeCeiling = 99;

/// 「替换素材」tab 上的角标文案：**已经挑好了几条素材**。
///
/// 曾经数的是「设了替换方式的单元数」，于是出现过：U1 切到「镜头替换」但
/// 六个镜头全是「原片」，角标却显示 1——用户点进去翻遍面板也找不到那一条
/// 到底是哪个。角标要么指向实实在在的东西，要么就别出现。
///
/// 返回 null 表示不显示（一条都没选时显示「0」会被读成「有 0 条可用素材」
/// 这种坏消息）。
String? candidateBadgeText(List<UnitReplacement> plan) {
  final count = plan.fold<int>(0, (sum, u) => sum + _pickedIn(u));
  if (count == 0) return null;
  return count > _badgeCeiling ? '$_badgeCeiling+' : '$count';
}

/// 一个单元里已挑好的素材条数。同一条素材被放到两个镜头上算两次——
/// 它确实要在成片里出现两处。
int _pickedIn(UnitReplacement unit) => switch (unit.mode) {
      ReplacementMode.keepOriginal => 0,
      ReplacementMode.whole => unit.wholeCandidateIds.length,
      ReplacementMode.perShot => unit.shotCandidateIds.values
          .fold<int>(0, (sum, ids) => sum + ids.length),
    };
