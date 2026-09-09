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

  /// 这一镜在**成片**里从第几毫秒开始。
  ///
  /// 界面上所有时间数字都该是成片时间——存的是原片毫秒（那是切分点），
  /// 显示的是它在成片里落到哪儿，每次现算。
  ///
  /// **整体替换的单元返回 null**：那一段整个换成了另一条素材，原片的镜头
  /// 切分在成片里已经不存在了。按比例缩一个数出来是假精度，而人会拿它去对时。
  /// 下标越界也返回 null——界面在编辑过程中会短暂拿到对不上的下标。
  int? composedShotStart(int unitIndex, int shotIndex) =>
      _composedShot(unitIndex, shotIndex, end: false);

  /// 这一镜在**成片**里到第几毫秒结束。约定同 [composedShotStart]
  int? composedShotEnd(int unitIndex, int shotIndex) =>
      _composedShot(unitIndex, shotIndex, end: true);

  int? _composedShot(int unitIndex, int shotIndex, {required bool end}) {
    if (unitIndex < 0 || unitIndex >= units.length) return null;
    if (isReplaced(unitIndex)) return null;
    final unit = units[unitIndex];
    if (shotIndex < 0 || shotIndex >= unit.shots.length) return null;
    final shot = unit.shots[shotIndex];
    final offset = (end ? shot.endMs : shot.startMs) - unit.startMs;
    return _starts[unitIndex] + offset;
  }

  /// 两条轴画出来是不是一模一样。
  ///
  /// **界面靠它判断要不要换轴**。原来只比 [totalMs]——而调整单元顺序恰恰
  /// 不改变总时长，于是时间线一直用着拖动之前那份轴：左栏顺序改了、时间线
  /// 纹丝不动（2026-09-07 真机 bug）。
  ///
  /// 比的是「每一格从哪儿开始、多长、取自原片的哪一段」——顺序一变，
  /// 后两样至少有一个跟着变。
  ///
  /// **镜头也要比**：镜头在成片上的位置是从这条轴里的那份镜头列表算出来的
  /// （见 [composedShotStart]）。合并/拆分/拖边界只动单元**内部**，上面那
  /// 四样一个都不变——只比它们的话会判成「轴没变」，时间线继续用着改动
  /// 之前那条轴：画的时候拿新列表的下标去问旧列表，位置全是旧的。
  ///
  /// 2026-09-09 真机，用户原话：「合并为什么还是这样子」——合并完两镜，
  /// 那个单元的镜头轨尾部空出一截（旧列表比新列表多两格，多出来的地盘
  /// 没人画），点下去命中的还是另一格。
  bool sameLayoutAs(ComposedTimeline other) {
    if (units.length != other.units.length) return false;
    for (var i = 0; i < units.length; i++) {
      if (_starts[i] != other._starts[i]) return false;
      if (_durations[i] != other._durations[i]) return false;
      // 长度和起点都一样、但换的是另一段原片：画面内容变了，也得重画
      if (units[i].startMs != other.units[i].startMs) return false;
      if (units[i].endMs != other.units[i].endMs) return false;
      final shots = units[i].shots;
      final otherShots = other.units[i].shots;
      if (shots.length != otherShots.length) return false;
      for (var s = 0; s < shots.length; s++) {
        if (shots[s].startMs != otherShots[s].startMs) return false;
        if (shots[s].endMs != otherShots[s].endMs) return false;
      }
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
  /// **已删除 `toComposedMs`（原片时刻 → 成片时刻）。**
  ///
  /// 这个方向病态：给一个原片时刻问它在成片哪儿，本身没有唯一答案——
  /// 可能无人覆盖（手加的单元）、可能多人覆盖，而 `endMs` 是开区间，
  /// 边界必然落到相邻那一段身上。列表顺序和原片顺序一致时恰好相等，
  /// 所以平时看不出来；拖动调序是一等功能，一调就失效。
  ///
  /// 要「这一段在成片哪儿」，按**列表下标**问 [startOf] / [durationOf] /
  /// [composedShotStart] / [composedShotEnd]。
  /// 反方向 [toSourceMs] 是良定义的，保留。
  ///
  /// 见 `docs/2026-09-08-成片时间轴重构-TRD.md` 二、2.2。


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
