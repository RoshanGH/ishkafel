import '../log/app_log.dart';

/// 任务选定的 miaoa 项目（不可变）。
///
/// 与 [TagGroupRef] 同样同时留 id 与名字：**id** 是检索时真正带给 CLI 的
/// `--projects` 值，**名字** 是给人看的。只留 id 会让界面退化成一串数字；
/// 只留名字则项目改名后检索直接错位。
///
/// 任务上为 null 表示不限项目（= 我的全部项目聚合）。
class ProjectRef {
  final int id;
  final String name;

  const ProjectRef({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  /// 宽松解析：缺失或类型不符一律返回 null（= 不限项目），绝不抛异常——
  /// 抛出会让整条任务读不出来，用户看到的是「我的任务不见了」。
  static ProjectRef? tryFromJson(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) {
      AppLog.warn('任务项目字段不是对象（${raw.runtimeType}），按不限项目处理');
      return null;
    }
    final id = raw['id'];
    final name = raw['name'];
    if (id is! int || name is! String) {
      AppLog.warn('任务项目字段缺失或类型不符（id=$id, name=$name），按不限项目处理');
      return null;
    }
    return ProjectRef(id: id, name: name);
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectRef && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'ProjectRef($id, $name)';
}
