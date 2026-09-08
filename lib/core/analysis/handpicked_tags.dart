import '../models/semantic_unit.dart';
import '../models/shot.dart';

/// 手改标签，以及「重新打标时别盖掉人改过的」。
///
/// 属性栏和审核页都能手改标签——那是人照着画面做的判断。重新打标会让模型
/// 照台词再打一遍，如果不避开手改过的，人的结论就被一个后台步骤抹掉了，
/// 而且不问一声：他不会想到是被盖了，只会觉得「改了没生效」。

/// 手改这个单元的标签。
///
/// 顺带**清掉 tagsStale**：「过期」说的是「模型打的标签配不上现在的边界」，
/// 而人刚照着画面判断过，再挂一个催他重打的标记只是噪音。
SemanticUnit withHandpickedTags(SemanticUnit unit, List<String> tags) =>
    unit.copyWith(
      tags: List.unmodifiable(tags),
      tagsHandpicked: true,
      tagsStale: false,
    );

/// 手改这一镜的标签（理由同上）
Shot withHandpickedShotTags(Shot shot, List<String> tags) => shot.copyWith(
      tags: List.unmodifiable(tags),
      tagsHandpicked: true,
      tagsStale: false,
    );

/// 重新打标时该打哪几个单元——**人改过的不打**
Set<int> unitsToRetag(List<SemanticUnit> units) => {
      for (var i = 0; i < units.length; i++)
        if (!units[i].tagsHandpicked) i,
    };

/// 这个单元里，重新打标要跳过的镜头下标（人改过的那些）
Set<int> shotsToSkip(SemanticUnit unit) => {
      for (var i = 0; i < unit.shots.length; i++)
        if (unit.shots[i].tagsHandpicked) i,
    };
