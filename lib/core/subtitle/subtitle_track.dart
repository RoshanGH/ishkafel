import 'package:collection/collection.dart';

import 'subtitle_overlay.dart';

/// 一个字幕坑位：被替换的那个视觉镜头。
///
/// **绑镜头，不绑素材**：同一镜可以挑好几条候选（导出几条变体），口播是同一句，
/// 字幕当然也是同一份。镜头替换是变速对齐原坑位、时长不变，所以这份字幕的
/// 时间轴在各条变体上通用。
///
/// **按单元的身份记，不按位置**（[SemanticUnit.uid]）。按位置记的时候，
/// 挪一次单元、删一次单元都要人工把它跟着搬——2026-09-09 清点才发现这一份
/// 从头到尾就没搬过：人给 U3 改好的那句会烧到 U2 的画面上，不报错。
/// 镜头下标照旧按位置：镜头是跟着单元整体搬家的。
class SubtitleSlot {
  final String unitUid;
  final int shotIndex;

  const SubtitleSlot({required this.unitUid, required this.shotIndex});

  @override
  bool operator ==(Object other) =>
      other is SubtitleSlot &&
      other.unitUid == unitUid &&
      other.shotIndex == shotIndex;

  @override
  int get hashCode => Object.hash(unitUid, shotIndex);

  @override
  String toString() => '$unitUid·S${shotIndex + 1}';
}

/// **手改过的**字幕。只有被替换的视觉镜头才会进来。
///
/// 为什么要有它：字幕默认是按 ASR 的词级时间戳切出来的，而「哪里断句好看」
/// 是编导的判断，规则算不对——真机上 S1/S2 都换了素材，「了」的声音落在 S2，
/// 于是 S2 的字幕以一个孤零零的「了」开头。ASR 没错、切点也没错，只是没人
/// 能替编导决定这个字该归哪句。
///
/// **字幕是字幕，台词是台词**：改这里不动 [SemanticUnit.transcript]——
/// 打标、检索、换音色照旧用台词。
///
/// **整份存，不存 diff**：只存改动的话，「我把这一段删空了」和「本来就没算出
/// 字幕」在数据上长得一模一样，导出时分不出来，会把用户删掉的字又贴回去。
class SubtitleTrack {
  final Map<SubtitleSlot, List<SubtitleLine>> _edited;

  const SubtitleTrack._(this._edited);

  const SubtitleTrack.empty() : _edited = const {};

  bool get isEmpty => _edited.isEmpty;

  /// 这个坑位手改过的字幕。**null = 没改过**（导出照 ASR 现算）；
  /// 空列表 = 改过、而且被清空了（那一镜就是不要字幕）
  List<SubtitleLine>? linesOf(SubtitleSlot slot) => _edited[slot];

  /// 哪些坑位被手改过。界面要标出来；切分变了也要照着它问「清除还是保留」
  Iterable<SubtitleSlot> get editedSlots => _edited.keys;

  SubtitleTrack withLines(SubtitleSlot slot, List<SubtitleLine> lines) =>
      SubtitleTrack._({
        ..._edited,
        slot: List.unmodifiable(lines),
      });

  /// 改回自动：清掉这个坑位，导出重新按 ASR 算
  SubtitleTrack cleared(SubtitleSlot slot) =>
      SubtitleTrack._({..._edited}..remove(slot));

  /// 删掉一个单元之后：把没人认领的那几句丢掉。
  ///
  /// **挪动顺序什么都不用做**——坑位按单元的身份记，单元怎么排都还是它。
  /// 删单元也只是「这个身份没了」，剩下的一份都不动。
  SubtitleTrack keepingOnly(Set<String> liveUids) {
    if (_edited.isEmpty) return this;
    final kept = {
      for (final e in _edited.entries)
        if (liveUids.contains(e.key.unitUid)) e.key: e.value,
    };
    return kept.length == _edited.length ? this : SubtitleTrack._(kept);
  }

  List<Map<String, dynamic>> toJson() => [
        for (final e in _edited.entries)
          {
            'unit': e.key.unitUid,
            'shot': e.key.shotIndex,
            'lines': [
              for (final l in e.value)
                {'startMs': l.startMs, 'endMs': l.endMs, 'text': l.text},
            ],
          },
      ];

  /// **脏数据一律跳过，绝不抛**：一条读不动的记录不该让整条任务打不开
  ///
  /// [uidAt] 是给**老存档**用的：那时坑位按单元下标记，读的时候要把下标
  /// 翻译成身份。返回 null 表示那个下标已经不存在（单元被删过），这条丢掉
  factory SubtitleTrack.fromJson(Object? json,
      {String? Function(int unitIndex)? uidAt}) {
    if (json is! List) return const SubtitleTrack.empty();
    final out = <SubtitleSlot, List<SubtitleLine>>{};
    for (final raw in json) {
      if (raw is! Map) continue;
      final unit = raw['unit'];
      final shot = raw['shot'];
      final lines = raw['lines'];
      if (shot is! int || lines is! List) continue;
      final uid = unit is String
          ? unit
          : (unit is int ? uidAt?.call(unit) : null);
      if (uid == null || uid.isEmpty) continue;
      out[SubtitleSlot(unitUid: uid, shotIndex: shot)] = List.unmodifiable([
        for (final l in lines)
          if (l is Map && l['startMs'] is int && l['endMs'] is int)
            SubtitleLine(
              startMs: l['startMs'] as int,
              endMs: l['endMs'] as int,
              text: '${l['text'] ?? ''}',
            ),
      ]);
    }
    return SubtitleTrack._(Map.unmodifiable(out));
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleTrack &&
      const DeepCollectionEquality().equals(other._edited, _edited);

  @override
  int get hashCode => const DeepCollectionEquality().hash(_edited);
}
