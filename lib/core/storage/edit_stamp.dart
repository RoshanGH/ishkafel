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
class EditStamp {
  final ActorKind by;
  final DateTime at;

  const EditStamp({required this.by, required this.at});

  Map<String, dynamic> toJson() =>
      {'by': by.name, 'at': at.toIso8601String()};

  /// 宽松解析：**任何一处不对就返回 null**。一个读不懂的戳不该废掉整条任务
  static EditStamp? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at']}');
    if (at == null) return null;
    final by = ActorKind.values.firstWhere((k) => k.name == raw['by'],
        orElse: () => ActorKind.agent);
    return EditStamp(by: by, at: at);
  }
}

/// 戳记在哪儿：**一律按 `SemanticUnit.uid`，不按下标**。
///
/// 任务里按单元下标记的数据已经有三份（`replacements` / `voices` / `bgm`），
/// 每加一份都得改 `blank_unit_removal.dart` / `unit_reorder.dart` 两个补偿
/// 函数——而且漏过一次：删掉 U2 之后本该念 U3 的配音跑到了 U2 身上，不报错，
/// 只有听出来才知道。按 uid 记就不用进那两个文件。
String stampKeyForUnit(String uid) => 'u:$uid';

String stampKeyForShot(String uid, int shotIndex) => 'u:$uid/s:$shotIndex';
