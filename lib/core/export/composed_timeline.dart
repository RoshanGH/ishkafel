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

  /// 两条轴画出来是不是一模一样。
  ///
  /// **界面靠它判断要不要换轴**。原来只比 [totalMs]——而调整单元顺序恰恰
  /// 不改变总时长，于是时间线一直用着拖动之前那份轴：左栏顺序改了、时间线
  /// 纹丝不动（2026-09-07 真机 bug）。
  ///
  /// 比的是「每一格从哪儿开始、多长、取自原片的哪一段」——顺序一变，
  /// 后两样至少有一个跟着变。
  bool sameLayoutAs(ComposedTimeline other) {
    if (units.length != other.units.length) return false;
    for (var i = 0; i < units.length; i++) {
      if (_starts[i] != other._starts[i]) return false;
      if (_durations[i] != other._durations[i]) return false;
      // 长度和起点都一样、但换的是另一段原片：画面内容变了，也得重画
      if (units[i].startMs != other.units[i].startMs) return false;
      if (units[i].endMs != other.units[i].endMs) return false;
    }
    return true;
  }

  /// 一段配乐覆盖的单元在**成片**里的时间区间；没有单元时 null
  (int, int)? rangeOfUnits(int fromUnit, int toUnit) {
    if (units.isEmpty) return null;
    final lo = fromUnit.clamp(0, units.length - 1);
    final hi = toUnit.clamp(lo, units.length - 1);
    return (_starts[lo], _starts[hi] + _durations[hi]);
  }

  /// 这个单元被整体替换了吗。时间线上它要画成一整块（原来的那些视觉镜头
  /// 在成片里已经不存在了——整段换成了另一条素材）
  bool isReplaced(int unitIndex) {
    final replaced = wholeDurations[unitIndex];
    if (replaced == null || replaced <= 0) return false;
    if (unitIndex < 0 || unitIndex >= units.length) return false;
    return replaced != units[unitIndex].endMs - units[unitIndex].startMs;
  }

  /// 原片的某一刻画在成片时间轴的哪儿。**时间线要用**：格子按成片长度画，
  /// 整体替换之后那一格就该变窄/变宽，后面的跟着挪——用户看到的宽度就是
  /// 它在成片里真实的长度，不必在脑子里再换算一次。
  int toComposedMs(int sourceMs) {
    if (units.isEmpty) return 0;
    // **按「谁的原片区间盖住它」找，不能顺序扫着比大小**：单元可以被拖乱
    // 顺序（列表顺序 = 成片顺序，startMs 只说明取自原片哪一段），顺序扫会
    // 先撞上排在前面、但原片时间更靠后的那个单元
    for (var i = 0; i < units.length; i++) {
      if (sourceMs < units[i].startMs || sourceMs >= units[i].endMs) continue;
      final into = sourceMs - units[i].startMs;
      final sourceLen = units[i].endMs - units[i].startMs;
      if (sourceLen <= 0 || _durations[i] == sourceLen) {
        return _starts[i] + into;
      }
      return _starts[i] + (into * _durations[i] / sourceLen).round();
    }
    // 落在所有单元的原片区间之外（比如手动加的单元占的那段时间）：
    // 夹到最近的一端，别返回一个凭空的数字
    var earliest = units.first;
    var latest = units.first;
    var latestIndex = 0;
    for (var i = 0; i < units.length; i++) {
      if (units[i].startMs < earliest.startMs) earliest = units[i];
      if (units[i].endMs > latest.endMs) {
        latest = units[i];
        latestIndex = i;
      }
    }
    if (sourceMs <= earliest.startMs) return 0;
    return _starts[latestIndex] + _durations[latestIndex];
  }

  /// 成片上的某一刻落在**第几个单元**上。
  ///
  /// 走 [_starts]/[_durations]——它们本来就是按列表顺序连续排出来的，
  /// 所以单元怎么拖都对。**命中测试一律走这条**：拿原片时间去列表里顺序扫
  /// （老写法）在单元被排过序之后必错。
  ///
  /// 落在片头之前夹到 0、片尾之后夹到最后一个：用户框选时手会滑出片子，
  /// 这时该夹住而不是让选区突然消失。
  int unitIndexAtComposedMs(int composedMs) {
    if (units.isEmpty) return 0;
    if (composedMs < 0) return 0;
    for (var i = 0; i < units.length; i++) {
      if (composedMs < _starts[i] + _durations[i]) return i;
    }
    return units.length - 1;
  }

  /// 成片上的某一刻对应原片的哪一刻。**命中测试要用**：用户点在成片轴上，
  /// 而选中的是原片切分里的单元/镜头。
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
