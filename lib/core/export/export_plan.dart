import '../models/semantic_unit.dart';
import '../replacement/replacement_plan.dart';

/// 成片里的一段。要么用原片这一段，要么用一条候选素材顶上去。
class ExportSegment {
  /// 这一段在原片里的位置（毫秒）。用候选素材顶替时，它同时是「这一段该占
  /// 多长」——候选比它长就裁、短就补，时长必须对齐，否则后面所有段都错位。
  final int startMs;
  final int endMs;

  /// 顶上来的候选素材 id；null 表示用原片
  final int? candidateId;

  /// 这一段来自哪个台词语义单元 / 哪个视觉镜头（镜头层替换时才有）。
  /// 导出失败时要能指着说「U3 的 S2 那一段没合成成功」。
  final int unitIndex;
  final int? shotIndex;

  /// **整体替换**时这一段在成片里真正占多长。
  ///
  /// 整体替换是「原样接上」——时长跟候选走，不裁不补（见四种替换的导出
  /// 规格）。而 [startMs]~[endMs] 记的是原片那一段的位置，两者不再相等。
  /// 不区分的话，确认页会按原片长度报「每条约 96.2s」，而实际导出来的是
  /// 97.2s——用户当场就能看出对不上。
  ///
  /// 为 null 表示与原片同长（保留原片、镜头替换都属于这一类：镜头替换是
  /// 变速对齐原坑位，时长不变）。
  final int? composedMs;

  const ExportSegment({
    required this.startMs,
    required this.endMs,
    required this.unitIndex,
    this.shotIndex,
    this.candidateId,
    this.composedMs,
  });

  /// 这一段在**成片**里占多长
  int get durationMs => composedMs ?? (endMs - startMs);

  /// 这一段在**原片**里的跨度（切原片时用）
  int get sourceDurationMs => endMs - startMs;
  bool get isOriginal => candidateId == null;

  @override
  bool operator ==(Object other) =>
      other is ExportSegment &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.candidateId == candidateId &&
      other.unitIndex == unitIndex &&
      other.shotIndex == shotIndex &&
      other.composedMs == composedMs;

  @override
  int get hashCode => Object.hash(
      startMs, endMs, candidateId, unitIndex, shotIndex, composedMs);

  @override
  String toString() => 'ExportSegment(U${unitIndex + 1}'
      '${shotIndex == null ? '' : '/S${shotIndex! + 1}'} '
      '$startMs~$endMs${candidateId == null ? ' 原片' : ' →$candidateId'})';
}

/// 一条要导出的成片：按时间顺序排好的若干段
class ExportCombination {
  /// 第几条（从 1 开始），用于文件名与进度显示
  final int index;
  final List<ExportSegment> segments;

  ExportCombination({required this.index, required List<ExportSegment> segments})
      : segments = List.unmodifiable(segments);

  /// 这一条里有几段是换过的。全是原片的那一条要能被认出来——
  /// 用户往往想把它排除掉（导出来跟原片一模一样）。
  int get replacedCount => segments.where((s) => !s.isOriginal).length;

  int get durationMs =>
      segments.fold<int>(0, (sum, s) => sum + s.durationMs);
}

/// 把「替换方案」摊平成「要导出哪几条、每条由哪些段拼成」。
///
/// 枚举顺序是**里程表式**：最后一个单元变化最快，第一个单元变化最慢。这样
/// 前几条成片之间只有片尾不同，用户对着导出目录一眼就能看出规律；随机顺序
/// 会让「这一批到底覆盖了什么」变得没法核对。
class ExportPlanner {
  ExportPlanner._();

  /// 枚举全部组合。[limit] 是硬上限（产品已定 100 条），超出部分不生成——
  /// 上层负责在这之前就拦住并让用户减，这里只是最后一道闸。
  static List<ExportCombination> enumerate({
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    int limit = ReplacementPlan.maxCombinations,

    /// 候选素材各有多长（候选 id → 毫秒）。**整体替换的段落靠它算成片时长**
    /// ——那一层是原样接上，时长跟候选走。取不到的按原单元长度算，
    /// 宁可报得保守，也不拿 0 顶
    Map<int, int> materialDurations = const {},
  }) {
    if (units.isEmpty || limit <= 0) return const [];

    // 每个单元的「可选项」列表：每一项是这个单元的一种排法
    final choicesPerUnit = <List<List<ExportSegment>>>[
      for (var i = 0; i < units.length; i++)
        _choicesFor(units[i], i < replacements.length ? replacements[i] : null,
            materialDurations),
    ];

    final out = <ExportCombination>[];
    final cursor = List<int>.filled(units.length, 0);
    while (out.length < limit) {
      out.add(ExportCombination(
        index: out.length + 1,
        segments: [
          for (var i = 0; i < units.length; i++) ...choicesPerUnit[i][cursor[i]],
        ],
      ));
      // 里程表进位：从最后一个单元开始加
      var i = units.length - 1;
      while (i >= 0) {
        cursor[i]++;
        if (cursor[i] < choicesPerUnit[i].length) break;
        cursor[i] = 0;
        i--;
      }
      if (i < 0) break; // 全部进位完毕 = 枚举结束
    }
    return List.unmodifiable(out);
  }

  /// 这个单元有几种排法，每种排法由哪些段组成
  static List<List<ExportSegment>> _choicesFor(SemanticUnit unit,
      UnitReplacement? replacement, Map<int, int> materialDurations) {
    final original = [
      ExportSegment(
          startMs: unit.startMs, endMs: unit.endMs, unitIndex: unit.index),
    ];
    if (replacement == null) return [original];

    switch (replacement.mode) {
      case ReplacementMode.keepOriginal:
        return [original];

      case ReplacementMode.whole:
        if (replacement.wholeCandidateIds.isEmpty) return [original];
        // 整体替换：整个单元换成这一条候选，一条候选一种排法
        return [
          for (final id in replacement.wholeCandidateIds)
            [
              ExportSegment(
                startMs: unit.startMs,
                endMs: unit.endMs,
                unitIndex: unit.index,
                candidateId: id,
                // 整体替换是原样接上，成片时长跟候选走。探不出来就按原单元
                // 算——报得保守好过拿 0 顶（那会把总时长算成一团）
                composedMs: materialDurations[id],
              ),
            ],
        ];

      case ReplacementMode.perShot:
        return _perShotChoices(unit, replacement);
    }
  }

  /// 镜头层：单元内各镜头的候选做笛卡尔积；没选候选的镜头恒用原画面。
  ///
  /// 同样是里程表顺序（最后一个镜头变化最快），与单元层保持一致——两层用
  /// 不同的顺序，导出目录里的规律就没法用一句话说清了。
  static List<List<ExportSegment>> _perShotChoices(
      SemanticUnit unit, UnitReplacement replacement) {
    // 每个镜头的候选（没选的用 [null] 表示「就用原画面」）
    final perShot = <List<int?>>[
      for (var s = 0; s < unit.shots.length; s++)
        (replacement.shotCandidateIds[s]?.isNotEmpty ?? false)
            ? [...replacement.shotCandidateIds[s]!]
            : <int?>[null],
    ];
    if (perShot.isEmpty) {
      return [
        [
          ExportSegment(
              startMs: unit.startMs, endMs: unit.endMs, unitIndex: unit.index),
        ],
      ];
    }

    final out = <List<ExportSegment>>[];
    final cursor = List<int>.filled(perShot.length, 0);
    while (true) {
      out.add([
        for (var s = 0; s < unit.shots.length; s++)
          ExportSegment(
            startMs: unit.shots[s].startMs,
            endMs: unit.shots[s].endMs,
            unitIndex: unit.index,
            shotIndex: s,
            candidateId: perShot[s][cursor[s]],
          ),
      ]);
      var s = perShot.length - 1;
      while (s >= 0) {
        cursor[s]++;
        if (cursor[s] < perShot[s].length) break;
        cursor[s] = 0;
        s--;
      }
      if (s < 0) break;
    }
    return out;
  }
}
