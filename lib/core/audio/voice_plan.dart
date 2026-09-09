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

/// 某个台词语义单元换成哪个音色。
///
/// **按单元的身份记，不按位置**（[SemanticUnit.uid]）：位置一挪，本该念 U3
/// 的配音就会跑到 U2 身上——2026-09-07 真机上就是这么错的，而且不报错，
/// 只有听出来才知道。
class VoiceAssignment {
  final String unitUid;
  final VoiceRef voice;

  const VoiceAssignment({required this.unitUid, required this.voice});

  Map<String, dynamic> toJson() =>
      {'unitUid': unitUid, 'voice': voice.toJson()};

  /// [uidAt] 是给**老存档**用的：那时按 `unitIndex` 记，读的时候翻译成身份。
  /// 返回 null 表示那个下标已经不存在，这条丢掉
  static VoiceAssignment? tryFromJson(Object? raw,
      {String? Function(int unitIndex)? uidAt}) {
    if (raw is! Map) return null;
    final voice = VoiceRef.tryFromJson(raw['voice']);
    if (voice == null) return null;
    final uid = raw['unitUid'];
    if (uid is String && uid.isNotEmpty) {
      return VoiceAssignment(unitUid: uid, voice: voice);
    }
    final index = raw['unitIndex'];
    if (index is! int || index < 0) return null;
    final migrated = uidAt?.call(index);
    if (migrated == null || migrated.isEmpty) return null;
    return VoiceAssignment(unitUid: migrated, voice: voice);
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
  VoiceRef? voiceOf(String unitUid) =>
      assignments.firstWhereOrNull((a) => a.unitUid == unitUid)?.voice;

  /// 所有被指定了音色的单元身份
  Set<String> get assignedUnits =>
      Set.unmodifiable({for (final a in assignments) a.unitUid});

  /// 给若干单元指定同一个音色。已经指定过的单元被覆盖——同一个单元留两条
  /// 记录，导出时不知道该听谁的。
  VoicePlan assign(Iterable<String> unitUids, VoiceRef voice) {
    final targets = unitUids.toSet();
    return VoicePlan(List.unmodifiable([
      for (final a in assignments)
        if (!targets.contains(a.unitUid)) a,
      for (final uid in targets) VoiceAssignment(unitUid: uid, voice: voice),
    ]));
  }

  /// 取消指定，回到原声
  VoicePlan clear(Iterable<String> unitUids) {
    final targets = unitUids.toSet();
    return VoicePlan(List.unmodifiable([
      for (final a in assignments)
        if (!targets.contains(a.unitUid)) a,
    ]));
  }

  /// 删掉单元之后：把没人认领的那几条丢掉。
  /// **挪动顺序什么都不用做**——按身份记，单元怎么排都还是它
  VoicePlan keepingOnly(Set<String> liveUids) {
    final kept = [
      for (final a in assignments)
        if (liveUids.contains(a.unitUid)) a,
    ];
    return kept.length == assignments.length
        ? this
        : VoicePlan(List.unmodifiable(kept));
  }

  List<Map<String, dynamic>> toJson() =>
      [for (final a in assignments) a.toJson()];

  /// 值相等：时间线的 shouldRepaint 靠它判断要不要重画。不实现的话每帧
  /// 都判定为「变了」，播放时每秒重画 30 次整条时间线。
  @override
  bool operator ==(Object other) {
    if (other is! VoicePlan) return false;
    if (other.assignments.length != assignments.length) return false;
    for (var i = 0; i < assignments.length; i++) {
      if (other.assignments[i].unitUid != assignments[i].unitUid ||
          other.assignments[i].voice != assignments[i].voice) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(
      [for (final a in assignments) Object.hash(a.unitUid, a.voice)]);

  /// 宽松解析：一条畸形只丢那一条。任务 JSON 里一处解析失败就让整条任务
  /// 从列表消失，用户看到的是「我的任务不见了」。
  static VoicePlan fromJson(Object? raw,
      {String? Function(int unitIndex)? uidAt}) {
    if (raw is! List) return empty;
    return VoicePlan(List.unmodifiable([
      for (final e in raw) ?VoiceAssignment.tryFromJson(e, uidAt: uidAt),
    ]));
  }
}
