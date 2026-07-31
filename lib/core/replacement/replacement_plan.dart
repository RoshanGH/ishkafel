/// 单个台词语义单元的替换模式（三态互斥）
///
/// 产品已定：整体替换与镜头级替换二选一，进入一方另一方锁定。
/// 这条约束在类型层面就体现出来——一个单元只有一个 [mode]，
/// 不存在「既整体替换又镜头级替换」的中间态。
enum ReplacementMode {
  /// 保留原片：不替换
  keepOriginal,

  /// 整体替换：整个单元换成候选素材（可多选，每个候选产出一条变体）
  whole,

  /// 镜头级替换：对单元内单个视觉镜头替换，未替换的镜头保留原画面
  perShot,
}

/// 一个台词语义单元的替换方案
class UnitReplacement {
  final ReplacementMode mode;

  /// 整体替换选中的候选素材 id（[mode] 为 [ReplacementMode.whole] 时有效）
  final List<int> wholeCandidateIds;

  /// 镜头级替换：镜头下标 → 该镜头选中的候选素材 id
  /// （[mode] 为 [ReplacementMode.perShot] 时有效；未出现的镜头保留原画面）
  final Map<int, List<int>> shotCandidateIds;

  UnitReplacement._({
    required this.mode,
    required List<int> wholeCandidateIds,
    required Map<int, List<int>> shotCandidateIds,
  })  : wholeCandidateIds = List.unmodifiable(wholeCandidateIds),
        shotCandidateIds = Map.unmodifiable({
          for (final e in shotCandidateIds.entries)
            e.key: List<int>.unmodifiable(e.value),
        });

  /// 保留原片
  factory UnitReplacement.keepOriginal() => UnitReplacement._(
        mode: ReplacementMode.keepOriginal,
        wholeCandidateIds: const [],
        shotCandidateIds: const {},
      );

  /// 整体替换。空候选列表等价于「还没选」，因子仍为 1
  factory UnitReplacement.whole(List<int> candidateIds) => UnitReplacement._(
        mode: ReplacementMode.whole,
        wholeCandidateIds: _dedupe(candidateIds),
        shotCandidateIds: const {},
      );

  /// 镜头级替换
  factory UnitReplacement.perShot(Map<int, List<int>> byShot) =>
      UnitReplacement._(
        mode: ReplacementMode.perShot,
        wholeCandidateIds: const [],
        shotCandidateIds: {
          for (final e in byShot.entries)
            if (e.value.isNotEmpty) e.key: _dedupe(e.value),
        },
      );

  /// 同一个候选被选两次不该让组合数翻倍
  static List<int> _dedupe(List<int> ids) {
    final seen = <int>{};
    return [
      for (final id in ids)
        if (seen.add(id)) id,
    ];
  }

  /// 该单元贡献的组合因子。
  ///
  /// - 保留原片 → 1
  /// - 整体替换 → 候选数（一个候选一条变体）；没选候选时为 1（等同保留原片）
  /// - 镜头级 → 单元内各视觉镜头候选数的**乘积**（未替换的镜头按 1 计）
  int get factor {
    switch (mode) {
      case ReplacementMode.keepOriginal:
        return 1;
      case ReplacementMode.whole:
        return wholeCandidateIds.isEmpty ? 1 : wholeCandidateIds.length;
      case ReplacementMode.perShot:
        return shotCandidateIds.values
            .fold<int>(1, (acc, ids) => acc * (ids.isEmpty ? 1 : ids.length));
    }
  }

  /// 是否真的会产生替换（用于「一条都没选就导出」的提示）
  bool get producesReplacement => factor > 1;
}

/// 整片的替换方案与矩阵导出规模
class ReplacementPlan {
  /// 按台词语义单元顺序排列，长度应与单元数一致
  final List<UnitReplacement> units;

  /// 组合数上限（产品已定：100 条，超过不允许导出）
  static const int maxCombinations = 100;

  ReplacementPlan(List<UnitReplacement> units)
      : units = List.unmodifiable(units);

  /// 全片组合数 = 各单元因子的笛卡尔积。
  ///
  /// 用**带饱和的乘法**：60 个单元各选 2 个候选就是 2^60，普通 int 乘法会溢出
  /// 成负数或绕回小值，界面上会显示一个荒谬的组合数、甚至让「是否超限」的
  /// 判断反转。一旦超过上限就停在哨兵值，反正超限本身已经不允许导出。
  int get combinationCount {
    var total = 1;
    for (final unit in units) {
      final f = unit.factor;
      if (f <= 0) continue;
      if (total > maxCombinations ~/ f + 1) return _overLimit;
      total *= f;
      if (total > maxCombinations) return _overLimit;
    }
    return total;
  }

  /// 超限哨兵：比上限大 1，界面上按「超过上限」展示即可
  static const int _overLimit = maxCombinations + 1;

  bool get exceedsLimit => combinationCount > maxCombinations;

  /// 是否一条替换都没设置（组合数为 1 意味着导出结果与原片相同）
  bool get isEmpty => units.every((u) => !u.producesReplacement);
}
