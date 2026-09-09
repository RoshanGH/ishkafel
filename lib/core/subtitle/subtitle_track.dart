import 'package:collection/collection.dart';

import 'subtitle_overlay.dart';

/// 一个字幕坑位：被替换的那个视觉镜头。
///
/// **绑镜头，不绑素材**：同一镜可以挑好几条候选（导出几条变体），口播是同一句，
/// 字幕当然也是同一份。镜头替换是变速对齐原坑位、时长不变，所以这份字幕的
/// 时间轴在各条变体上通用。
class SubtitleSlot {
  final int unitIndex;
  final int shotIndex;

  const SubtitleSlot({required this.unitIndex, required this.shotIndex});

  @override
  bool operator ==(Object other) =>
      other is SubtitleSlot &&
      other.unitIndex == unitIndex &&
      other.shotIndex == shotIndex;

  @override
  int get hashCode => Object.hash(unitIndex, shotIndex);

  @override
  String toString() => 'U${unitIndex + 1}·S${shotIndex + 1}';
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

  /// 把所有坑位按 [move] 重新映射一遍——**挪动单元顺序时必须调**。
  ///
  /// 手改的字幕是按 `(单元下标, 镜头下标)` 记的，而单元下标就是列表位置。
  /// 挪了单元不搬它，人给 U3 改好的那句字幕会烧到 U2 的画面上——不报错，
  /// 只有把片子导出来看一遍才发现（2026-09-09 清点时查出来的，这条从来
  /// 没搬过）。镜头下标不动：镜头跟着单元整体搬家。
  SubtitleTrack remapped(int Function(int unitIndex) move) {
    if (_edited.isEmpty) return this;
    return SubtitleTrack._({
      for (final e in _edited.entries)
        SubtitleSlot(
            unitIndex: move(e.key.unitIndex), shotIndex: e.key.shotIndex): e.value,
    });
  }

  /// 删掉第 [removed] 个单元之后：它自己那几句丢掉，后面的整体前移
  SubtitleTrack afterRemoval(int removed) {
    if (_edited.isEmpty) return this;
    return SubtitleTrack._({
      for (final e in _edited.entries)
        if (e.key.unitIndex != removed)
          SubtitleSlot(
              unitIndex: e.key.unitIndex > removed
                  ? e.key.unitIndex - 1
                  : e.key.unitIndex,
              shotIndex: e.key.shotIndex): e.value,
    });
  }

  List<Map<String, dynamic>> toJson() => [
        for (final e in _edited.entries)
          {
            'unit': e.key.unitIndex,
            'shot': e.key.shotIndex,
            'lines': [
              for (final l in e.value)
                {'startMs': l.startMs, 'endMs': l.endMs, 'text': l.text},
            ],
          },
      ];

  /// **脏数据一律跳过，绝不抛**：一条读不动的记录不该让整条任务打不开
  factory SubtitleTrack.fromJson(Object? json) {
    if (json is! List) return const SubtitleTrack.empty();
    final out = <SubtitleSlot, List<SubtitleLine>>{};
    for (final raw in json) {
      if (raw is! Map) continue;
      final unit = raw['unit'];
      final shot = raw['shot'];
      final lines = raw['lines'];
      if (unit is! int || shot is! int || lines is! List) continue;
      out[SubtitleSlot(unitIndex: unit, shotIndex: shot)] = List.unmodifiable([
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
