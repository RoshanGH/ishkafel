import '../log/app_log.dart';

/// 任务选定的 miaoa 标签组引用（不可变）。
///
/// 同时保留 id 与名字是刻意的：
/// - **id** 是阶段②「按相同标签检索候选素材」真正要带的检索键；
/// - **名字** 是给人看的（顶栏、任务卡、向导），把 id 摆到界面上是技术黑话。
///
/// 只留 id 会让离线/接口失败时界面退化成一串数字；只留名字则组改名后检索直接错位。
class TagGroupRef {
  final int id;
  final String name;

  const TagGroupRef({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  /// 宽松解析：任务 JSON 是历史数据，字段缺失或类型不符一律返回 null。
  ///
  /// 绝不抛异常——抛出会让 [RenewTask.fromJson] 整体失败，用户看到的是
  /// 「我的任务不见了」。缺失（null）视为旧数据的正常形态、不告警；其余
  /// 非法形态记一条告警，便于排查脏数据来源。
  static TagGroupRef? tryFromJson(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) {
      AppLog.warn('任务标签组字段不是对象（${raw.runtimeType}），按未选择处理');
      return null;
    }
    final id = raw['id'];
    final name = raw['name'];
    if (id is! int || name is! String) {
      AppLog.warn('任务标签组字段缺失或类型不符（id=$id, name=$name），按未选择处理');
      return null;
    }
    return TagGroupRef(id: id, name: name);
  }

  @override
  bool operator ==(Object other) =>
      other is TagGroupRef && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'TagGroupRef($id, $name)';
}
