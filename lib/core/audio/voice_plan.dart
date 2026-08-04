import 'package:collection/collection.dart';

/// 一个可用的音色（预置音色或用户克隆出来的）
class VoiceRef {
  /// 合成时传给接口的标识（`speaker` / `voice_type`）
  final String id;

  /// 给人看的名字。只留 id 会让界面退化成一串 `zh_female_..._bigtts`
  final String name;

  const VoiceRef({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  static VoiceRef? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return VoiceRef(
        id: id, name: raw['name'] is String ? raw['name'] as String : id);
  }

  @override
  bool operator ==(Object other) =>
      other is VoiceRef && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// 某个台词语义单元换成哪个音色
class VoiceAssignment {
  final int unitIndex;
  final VoiceRef voice;

  const VoiceAssignment({required this.unitIndex, required this.voice});

  Map<String, dynamic> toJson() =>
      {'unitIndex': unitIndex, 'voice': voice.toJson()};

  static VoiceAssignment? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final index = raw['unitIndex'];
    if (index is! int || index < 0) return null;
    final voice = VoiceRef.tryFromJson(raw['voice']);
    if (voice == null) return null;
    return VoiceAssignment(unitIndex: index, voice: voice);
  }
}

/// 全片的换音色方案（不可变）。
///
/// 挂在**台词语义单元**这一层，不是视觉镜头：台词跟着单元走，换镜头不影响
/// 这句话是谁说的。没有指定音色的单元保持原声——这一点很重要，用户往往只
/// 想换其中几句，剩下的原声必须原封不动。
class VoicePlan {
  final List<VoiceAssignment> assignments;

  const VoicePlan(this.assignments);

  static const empty = VoicePlan([]);

  bool get isEmpty => assignments.isEmpty;

  /// 这个单元换成了哪个音色；没换返回 null（=保持原声）
  VoiceRef? voiceOf(int unitIndex) => assignments
      .firstWhereOrNull((a) => a.unitIndex == unitIndex)
      ?.voice;

  /// 所有被指定了音色的单元下标，升序
  List<int> get assignedUnits =>
      List.unmodifiable(assignments.map((a) => a.unitIndex).toList()..sort());

  /// 给若干单元指定同一个音色。已经指定过的单元被覆盖——同一个单元留两条
  /// 记录，导出时不知道该听谁的。
  VoicePlan assign(Iterable<int> unitIndexes, VoiceRef voice) {
    final targets = unitIndexes.toSet();
    return VoicePlan(List.unmodifiable([
      for (final a in assignments)
        if (!targets.contains(a.unitIndex)) a,
      for (final i in targets) VoiceAssignment(unitIndex: i, voice: voice),
    ]));
  }

  /// 取消指定，回到原声
  VoicePlan clear(Iterable<int> unitIndexes) {
    final targets = unitIndexes.toSet();
    return VoicePlan(List.unmodifiable([
      for (final a in assignments)
        if (!targets.contains(a.unitIndex)) a,
    ]));
  }

  List<Map<String, dynamic>> toJson() =>
      [for (final a in assignments) a.toJson()];

  /// 宽松解析：一条畸形只丢那一条。任务 JSON 里一处解析失败就让整条任务
  /// 从列表消失，用户看到的是「我的任务不见了」。
  static VoicePlan fromJson(Object? raw) {
    if (raw is! List) return empty;
    return VoicePlan(List.unmodifiable([
      for (final e in raw) ?VoiceAssignment.tryFromJson(e),
    ]));
  }
}
