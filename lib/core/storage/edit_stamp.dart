import 'task_log.dart';

/// 「我现在看到的这一处，是谁定的。」
///
/// 产品负责人的原话是「**如果你发现这个是人已经修改的**」——「发现」这个词要求
/// Agent 看当前数据时就能看见，而不是必须先去翻一遍时间线。所以除了日志
/// （[TaskLogEntry]，回答「发生过什么」），当前数据上还要盖一个戳，
/// 回答「这一处是谁定的」。
///
/// **只标事实，不给规则**：软件不说「人改过的不许动」，只说「这是人改的」。
/// 绕开还是照改是 Agent 的判断。
///
/// **戳长在对象上，不建旁挂表**：最初这里配了一套按路径字符串（`u:<uid>` /
/// `u:<uid>/s:<i>`）索引的 map 挂在 [RenewTask] 上，是为了避开「按单元下标记」
/// 的坑，结果自己新造了一个同类坑——`s:<shotIndex>` 照样是下标，
/// `SegmentationEditOps.splitShotAt` 在单元内部插入镜头、`mergeShotWithPrevious`
/// 删掉一个镜头，都会让同一单元里后续镜头的下标整体漂移，第一次拆镜头就会把
/// 戳错记到相邻镜头上，而且不报错。改成戳直接长在 [Shot] / [SemanticUnit]
/// 对象自己身上（挨着 `tagsHandpicked`——同一类「这是谁定的」的事实），
/// 拆镜头、并镜头时戳跟着对象本身走，天然不受下标漂移影响。
class EditStamp {
  final ActorKind by;
  final DateTime at;

  const EditStamp({required this.by, required this.at});

  Map<String, dynamic> toJson() =>
      {'by': by.name, 'at': at.toIso8601String()};

  /// 宽松解析：**任何一处不对就返回 null**。一个读不懂的戳不该废掉整条任务。
  ///
  /// **`by` 解析不出合法值也算坏行，不猜成某一方**（跟
  /// [TaskLogEntry.tryFromJson] 同一条规矩）。这个戳存在的唯一意义就是分清
  /// 人和 Agent——猜一个归属就是把「人 / Agent / 不知道」这三态悄悄压成两态，
  /// 而 Agent 看到「这是我自己定的」很可能直接覆盖掉人的东西，猜错代价太大。
  static EditStamp? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at']}');
    if (at == null) return null;
    ActorKind? by;
    for (final k in ActorKind.values) {
      if (k.name == raw['by']) {
        by = k;
        break;
      }
    }
    if (by == null) return null;
    return EditStamp(by: by, at: at);
  }

  // 值相等：这个戳要嵌进 [Shot] / [SemanticUnit] 的 `==`，那两个类的
  // 序列化往返测试（`expect(fromJson(toJson(x)), x)`）靠的就是深度相等，
  // 不重写的话读回来的新实例永远跟原对象不相等（默认是按引用比较）
  @override
  bool operator ==(Object other) =>
      other is EditStamp && other.by == by && other.at == at;

  @override
  int get hashCode => Object.hash(by, at);
}
