import '../models/semantic_unit.dart';

/// 成片的时间轴：**整体替换会改变单元的时长**，后面所有单元跟着挪。
///
/// 时间线画的是原片的切分（0~4000 是 U1、4000~10000 是 U2…），而整体替换把
/// U1 换成一条 5.2 秒的候选之后，成片里 U2 就从 5200 才开始。音轨、配乐区间、
/// 播放头位置全都要按**成片**的毫秒算，按原片算就会从被替换的那个单元之后
/// 全部错位。
///
/// 镜头替换不进这里——那一层是变速对齐到原坑位，时长不变（见 `SpeedFit`）。
class ComposedTimeline {
  final List<SemanticUnit> units;

  /// 单元下标 → 它在成片里的时长（毫秒）。只有被整体替换的单元才在这里
  final Map<int, int> wholeDurations;

  /// 各单元在成片里的起点（毫秒），与 [units] 同长
  final List<int> _starts;
  final List<int> _durations;

  const ComposedTimeline._(
      this.units, this.wholeDurations, this._starts, this._durations);

  static ComposedTimeline of({
    required List<SemanticUnit> units,
    required Map<int, int> wholeDurations,
  }) {
    final starts = <int>[];
    final durations = <int>[];
    var cursor = 0;
    for (var i = 0; i < units.length; i++) {
      final replaced = wholeDurations[i];
      final ms = replaced != null && replaced > 0
          ? replaced
          : units[i].endMs - units[i].startMs;
      starts.add(cursor);
      durations.add(ms);
      cursor += ms;
    }
    return ComposedTimeline._(
        units, Map.unmodifiable(wholeDurations), starts, durations);
  }

  /// 有没有单元的时长真的变了。没变时成片时间轴 == 原片时间轴，
  /// 上层可以走原来那条更快的路（比如所有变体共用一条音轨）
  bool get changed => units.asMap().entries.any((e) {
        final replaced = wholeDurations[e.key];
        return replaced != null &&
            replaced > 0 &&
            replaced != e.value.endMs - e.value.startMs;
      });

  int get totalMs => _durations.isEmpty ? 0 : _starts.last + _durations.last;

  int startOf(int unitIndex) => _starts[unitIndex.clamp(0, _starts.length - 1)];
  int durationOf(int unitIndex) =>
      _durations[unitIndex.clamp(0, _durations.length - 1)];

  /// 一段配乐覆盖的单元在**成片**里的时间区间；没有单元时 null
  (int, int)? rangeOfUnits(int fromUnit, int toUnit) {
    if (units.isEmpty) return null;
    final lo = fromUnit.clamp(0, units.length - 1);
    final hi = toUnit.clamp(lo, units.length - 1);
    return (_starts[lo], _starts[hi] + _durations[hi]);
  }

  /// 成片上的某一刻对应原片的哪一刻。**播放头要用**：时间线画的是原片切分，
  /// 而预览播的是成片。
  ///
  /// 落在被整体替换的单元里时按比例映射——那一段的画面根本不是原片的，
  /// 只能给一个「大致在这个单元的百分之几」的位置。
  int toSourceMs(int composedMs) {
    if (units.isEmpty) return 0;
    if (composedMs <= 0) return units.first.startMs;
    if (composedMs >= totalMs) return units.last.endMs;
    for (var i = 0; i < units.length; i++) {
      final end = _starts[i] + _durations[i];
      if (composedMs >= end) continue;
      final into = composedMs - _starts[i];
      final sourceLen = units[i].endMs - units[i].startMs;
      if (_durations[i] == sourceLen) return units[i].startMs + into;
      return units[i].startMs + (into * sourceLen / _durations[i]).round();
    }
    return units.last.endMs;
  }
}
