import '../models/semantic_unit.dart';

/// 空白任务里已填 / 未填的统计。
///
/// 分开记而不是给一个总时长：**占位长度是编出来的，不能算进全片时长**。
/// 界面上要显示的是「已填 3 个共 8.4 秒 · 还有 2 个没填」，用户任何时候
/// 看到的秒数都只统计真实挑到的素材。
class BlankFillStat {
  final int filledCount;
  final int emptyCount;

  /// 已填分子的真实总时长（毫秒）。**不含占位**
  final int filledMs;

  const BlankFillStat(
      {required this.filledCount,
      required this.emptyCount,
      required this.filledMs});

  /// 一个分子都没有时不算「全挑满」——那是空任务，不是完成
  bool get allFilled => filledCount > 0 && emptyCount == 0;
}

/// 空白任务的分子编辑：纯函数，绝不原地修改。
///
/// 跟 [SegmentationEditOps] 是两套不变量，所以分开放：
/// - 那边有一条固定的原片总长要无缝覆盖，边界要帧对齐，切分只能在既有范围里挪
/// - 这边没有原片，分子可以随便增删排序，**总长是加出来的**
///
/// 共同的不变量只有两条：下标与位置一致、时间首尾相接。前者是因为替换方案
/// 按下标记（改了顺序不重排下标，挑给某个分子的素材会跑到别人身上）；后者
/// 是因为时间线、命中测试、配乐区间全都以它为内部坐标。
abstract final class BlankUnitOps {
  /// 还没挑素材的分子在时间轴上占多长。
  ///
  /// **这不是「编造时长」**：格子上明确写着「待填」，而全片时长只统计已填的
  /// （见 [filledStat]）。给 0 的话格子是零宽，看不见也点不到，那更糟。
  static const int placeholderMs = 2000;

  static List<SemanticUnit> append(List<SemanticUnit> units,
      {List<String> tags = const []}) {
    final start = units.isEmpty ? 0 : units.last.endMs;
    return [
      ...units,
      SemanticUnit(
        index: units.length,
        startMs: start,
        endMs: start + placeholderMs,
        // 空白任务没有台词、也不分镜头——这两样本来就不存在
        transcript: '',
        tags: List.unmodifiable(tags),
        shots: const [],
      ),
    ];
  }

  static List<SemanticUnit> removeAt(List<SemanticUnit> units, int index) {
    if (index < 0 || index >= units.length) return units;
    return _renumber([...units]..removeAt(index));
  }

  static List<SemanticUnit> move(List<SemanticUnit> units, int from, int to) {
    if (from == to) return units;
    if (from < 0 || from >= units.length) return units;
    if (to < 0 || to >= units.length) return units;
    final next = [...units];
    next.insert(to, next.removeAt(from));
    return _renumber(next);
  }

  static List<SemanticUnit> setTags(
      List<SemanticUnit> units, int index, List<String> tags) {
    if (index < 0 || index >= units.length) return units;
    return [
      for (var i = 0; i < units.length; i++)
        if (i == index)
          // 手填的标签不存在「过期」：tagsStale 说的是「模型打的标签是编辑前
          // 打的」，这里没有模型参与
          units[i].copyWith(tags: List.unmodifiable(tags), tagsStale: false)
        else
          units[i],
    ];
  }

  /// 按每个分子已挑素材的实际时长重排时间轴。
  ///
  /// [durationOf] 返回 null（或非正数）表示这个分子还没挑素材，用占位长度。
  static List<SemanticUnit> relayout(
    List<SemanticUnit> units, {
    required int? Function(int index) durationOf,
  }) {
    final next = <SemanticUnit>[];
    var cursor = 0;
    for (var i = 0; i < units.length; i++) {
      final picked = durationOf(i);
      final span = (picked == null || picked <= 0) ? placeholderMs : picked;
      next.add(units[i]
          .copyWith(index: i, startMs: cursor, endMs: cursor + span));
      cursor += span;
    }
    return next;
  }

  static BlankFillStat filledStat(
    List<SemanticUnit> units, {
    required int? Function(int index) durationOf,
  }) {
    var filled = 0;
    var ms = 0;
    for (var i = 0; i < units.length; i++) {
      final picked = durationOf(i);
      if (picked != null && picked > 0) {
        filled++;
        ms += picked;
      }
    }
    return BlankFillStat(
        filledCount: filled, emptyCount: units.length - filled, filledMs: ms);
  }

  /// 下标必须跟位置一致：替换方案是按下标记的，排序后不重排下标，
  /// 原本挑给某个分子的素材会跑到别人身上
  static List<SemanticUnit> _renumber(List<SemanticUnit> units) {
    final next = <SemanticUnit>[];
    var cursor = 0;
    for (var i = 0; i < units.length; i++) {
      final span = units[i].durationMs <= 0 ? placeholderMs : units[i].durationMs;
      next.add(units[i]
          .copyWith(index: i, startMs: cursor, endMs: cursor + span));
      cursor += span;
    }
    return next;
  }
}
