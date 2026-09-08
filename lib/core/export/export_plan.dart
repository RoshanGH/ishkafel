import '../models/semantic_unit.dart';
import '../replacement/candidate_trim.dart';
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

  /// 从候选素材的第几毫秒开始截。null = 整条压缩进坑位（老行为）。
  ///
  /// 短坑位配长素材时，整条压缩就是十几二十倍的快放；截一段用倍速才回到 1.0
  final int? trimStartMs;

  const ExportSegment({
    required this.startMs,
    required this.endMs,
    required this.unitIndex,
    this.shotIndex,
    this.candidateId,
    this.composedMs,
    this.trimStartMs,
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

  /// 这条方案叫什么——**它就是文件名**。
  /// 界面上枚举出来的组合没有名字（null），走「变体N」
  final String? name;

  ExportCombination(
      {required this.index,
      required List<ExportSegment> segments,
      this.name})
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
/// 哪些单元**根本没东西可放**：原片上没有它（[SemanticUnit.hasSource] 为假，
/// 也就是用户手动加的），又一条候选素材都没挑。
///
/// 为什么必须单独拦一道：导出那边「没挑素材」一律走「用原片这一段」，
/// 而这些单元的 `startMs`~`endMs` 根本不指向原片的任何位置——真让它跑下去，
/// 出来的是一段空白或者直接崩在 ffmpeg 里，而人要等片子导完才发现。
///
/// 返回单元下标，调用方**必须指着说是哪几个**（「U3 还没挑素材」），
/// 不许拿黑帧顶上、也不许悄悄跳过这一段。
List<int> unitsWithNothingToShow(
  List<SemanticUnit> units,
  List<UnitReplacement> replacements,
) =>
    [
      for (var i = 0; i < units.length; i++)
        if (!units[i].hasSource && !_hasAnyCandidate(_planAt(replacements, i)))
          i,
    ];

UnitReplacement? _planAt(List<UnitReplacement> plans, int i) =>
    i < plans.length ? plans[i] : null;

bool _hasAnyCandidate(UnitReplacement? plan) {
  if (plan == null) return false;
  if (plan.wholeCandidateIds.isNotEmpty) return true;
  return plan.shotCandidateIds.values.any((ids) => ids.isNotEmpty);
}

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

    // 进位顺序：**候选最多的单元当最低位**（变化最快）。
    //
    // 里程表默认从最后一个单元开始进位，而候选最多的那个单元往往夹在中间——
    // 真机上 U2 选了几百个候选、后面还有 U3/U4，导出来的一百条里 U2 一动不动，
    // 等于白挑。名额有限，就该花在差异最大的那一维上。
    // 候选数相同时保持「后面的单元先变」——那是原本的里程表顺序，
    // 用户对着导出目录看到的规律（前几条只有片尾不同）不该无缘无故改掉
    final carryOrder = [for (var i = 0; i < units.length; i++) i]
      ..sort((a, b) {
        final byCount =
            choicesPerUnit[b].length.compareTo(choicesPerUnit[a].length);
        return byCount != 0 ? byCount : b.compareTo(a);
      });

    final out = <ExportCombination>[];
    final cursor = List<int>.filled(units.length, 0);
    // 里程表最多能走多少格。作废的组合不占 out 的名额，光靠 out.length
    // 收不住循环
    var steps = 0;
    final maxSteps = _stepBudget(choicesPerUnit, limit);
    while (out.length < limit && steps++ < maxSteps) {
      final segments = <ExportSegment>[
        for (var i = 0; i < units.length; i++) ...choicesPerUnit[i][cursor[i]],
      ];
      // 同一条素材在一条成片里出现两次，一眼就能看出来——那不是用户想要的。
      // 笛卡尔积会自然产出这种组合（U1 选 [A,B]、U2 选 [A,C] 里就有 A+A），
      // 在这儿滤掉，编号按**留下来的**顺延，不在编号上留洞
      if (!_hasDuplicateMaterial(segments)) {
        out.add(ExportCombination(index: out.length + 1, segments: segments));
      }
      // 里程表进位：从候选最多的单元开始加
      var k = 0;
      while (k < carryOrder.length) {
        final i = carryOrder[k];
        cursor[i]++;
        if (cursor[i] < choicesPerUnit[i].length) break;
        cursor[i] = 0;
        k++;
      }
      if (k >= carryOrder.length) break; // 全部进位完毕 = 枚举结束
    }
    return List.unmodifiable(out);
  }

  /// 一条成片里同一条素材出现了两次
  static bool _hasDuplicateMaterial(List<ExportSegment> segments) {
    final seen = <int>{};
    for (final segment in segments) {
      final id = segment.candidateId;
      if (id != null && !seen.add(id)) return true;
    }
    return false;
  }

  /// 里程表最多走多少格：所有排法的乘积，但不超过一个跟上限同量级的天花板。
  /// 去重会让「有效组合」少于总排法数，不设步数预算的话循环收不住
  static int _stepBudget(List<List<List<ExportSegment>>> choices, int limit) {
    var total = 1;
    final ceiling = limit * 10 + 100;
    for (final unitChoices in choices) {
      total *= unitChoices.isEmpty ? 1 : unitChoices.length;
      if (total >= ceiling) return ceiling;
    }
    return total;
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
        return _perShotChoices(unit, replacement, materialDurations);
    }
  }

  /// 镜头层：单元内各镜头的候选做笛卡尔积；没选候选的镜头恒用原画面。
  ///
  /// 同样是里程表顺序（最后一个镜头变化最快），与单元层保持一致——两层用
  /// 不同的顺序，导出目录里的规律就没法用一句话说清了。
  static List<List<ExportSegment>> _perShotChoices(SemanticUnit unit,
      UnitReplacement replacement, Map<int, int> materialDurations) {
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
          _shotSegment(
            unit: unit,
            shotIndex: s,
            candidateId: perShot[s][cursor[s]],
            replacement: replacement,
            materialDurations: materialDurations,
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

  /// 造一个镜头位的段，**顺手算好取段**。
  ///
  /// 短坑位是这条线最疼的地方：原片快切镜头 0.4~1 秒，素材库里的分镜普遍
  /// 4~30 秒，整条压缩就是十几二十倍快放。这里按 [trimFor] 截一段——
  /// 人调过起点就听人的，没调过取素材中段。
  static ExportSegment _shotSegment({
    required SemanticUnit unit,
    required int shotIndex,
    required int? candidateId,
    required UnitReplacement replacement,
    required Map<int, int> materialDurations,
  }) {
    final shot = unit.shots[shotIndex];
    if (candidateId == null) {
      return ExportSegment(
        startMs: shot.startMs,
        endMs: shot.endMs,
        unitIndex: unit.index,
        shotIndex: shotIndex,
      );
    }
    final materialMs = materialDurations[candidateId] ?? 0;
    final cut = trimFor(
      materialMs: materialMs,
      slotMs: shot.endMs - shot.startMs,
      startMs:
          replacement.trimStartOf(shotIndex: shotIndex, candidateId: candidateId),
    );
    return ExportSegment(
      startMs: shot.startMs,
      endMs: shot.endMs,
      unitIndex: unit.index,
      shotIndex: shotIndex,
      candidateId: candidateId,
      // 量不到素材时长时 trimFor 会退回整条压缩，那时不带起点
      trimStartMs: materialMs > 0 ? cut.startMs : null,
    );
  }
}
