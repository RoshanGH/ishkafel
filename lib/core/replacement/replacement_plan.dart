import 'package:collection/collection.dart';

import '../log/app_log.dart';

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

  /// 整体替换时，预览播的是哪一个候选。
  ///
  /// **预览只能放一个，导出会把选中的都用上**。为空表示还没选候选。
  /// 指到一个没选中的候选上时退回第一个——方案是存在盘上的，用户取消勾选
  /// 之后预览指向可能就没了。
  final int? wholePreviewId;

  /// 镜头替换时，各镜头预览播的是哪一个候选（镜头下标 → 候选 id）
  final Map<int, int> shotPreviewIds;

  /// 人手调过的取段起点：镜头下标 → 候选 id → 从素材第几毫秒起截。
  ///
  /// **没有记录的走自动**（见 [CandidateTrim]：素材比坑位长就截中段，
  /// 倍速 1.0）。只记人调过的那些——把自动值也存下来的话，以后改了默认策略，
  /// 老方案会永远停在旧值上。
  final Map<int, Map<int, int>> shotTrimStarts;

  /// 整体替换的取段起点：候选 id → 从素材第几毫秒起截
  final Map<int, int> wholeTrimStarts;

  UnitReplacement._({
    required this.mode,
    required List<int> wholeCandidateIds,
    required Map<int, List<int>> shotCandidateIds,
    int? wholePreviewId,
    Map<int, int> shotPreviewIds = const {},
    Map<int, Map<int, int>> shotTrimStarts = const {},
    Map<int, int> wholeTrimStarts = const {},
  })  : wholeCandidateIds = List.unmodifiable(wholeCandidateIds),
        wholeTrimStarts = Map.unmodifiable(wholeTrimStarts),
        shotTrimStarts = Map.unmodifiable({
          for (final e in shotTrimStarts.entries)
            e.key: Map<int, int>.unmodifiable(e.value),
        }),
        wholePreviewId = wholeCandidateIds.contains(wholePreviewId)
            ? wholePreviewId
            : (wholeCandidateIds.isEmpty ? null : wholeCandidateIds.first),
        shotPreviewIds = Map.unmodifiable({
          for (final e in shotCandidateIds.entries)
            if (e.value.isNotEmpty)
              e.key: e.value.contains(shotPreviewIds[e.key])
                  ? shotPreviewIds[e.key]!
                  : e.value.first,
        }),
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
  factory UnitReplacement.whole(List<int> candidateIds,
          {int? previewId, Map<int, int> trimStarts = const {}}) =>
      UnitReplacement._(
        mode: ReplacementMode.whole,
        wholeCandidateIds: _dedupe(candidateIds),
        shotCandidateIds: const {},
        wholePreviewId: previewId,
        wholeTrimStarts: trimStarts,
      );

  /// 镜头级替换
  factory UnitReplacement.perShot(Map<int, List<int>> byShot,
          {Map<int, int> previewIds = const {},
          Map<int, Map<int, int>> trimStarts = const {}}) =>
      UnitReplacement._(
        mode: ReplacementMode.perShot,
        wholeCandidateIds: const [],
        shotCandidateIds: {
          for (final e in byShot.entries)
            if (e.value.isNotEmpty) e.key: _dedupe(e.value),
        },
        shotPreviewIds: previewIds,
        shotTrimStarts: trimStarts,
      );

  /// 这个位置上这条候选，人调过的取段起点；没调过返回 null（走自动）
  int? trimStartOf({int? shotIndex, required int candidateId}) =>
      shotIndex == null
          ? wholeTrimStarts[candidateId]
          : shotTrimStarts[shotIndex]?[candidateId];

  /// 这个镜头预览播哪一个候选；没替换这个镜头时返回 null
  int? shotPreviewId(int shotIndex) => shotPreviewIds[shotIndex];

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

  /// 落盘形态。镜头下标用字符串键——JSON 对象的键只能是字符串，
  /// 直接塞 int 键的 Map 在 `jsonEncode` 时会抛。
  ///
  /// [unitUid] 是这条方案挂在哪个单元上（[SemanticUnit.uid]）。**数组仍然
  /// 按单元顺序写**：本项目按「打包好的 .app 发给同事」分发，新旧版本会并存，
  /// 旧版本只认位置——顺序写对，它读出来也还是对的。
  Map<String, dynamic> toJson({String unitUid = ''}) => {
        if (unitUid.isNotEmpty) 'unitUid': unitUid,
        'mode': mode.name,
        'wholeCandidateIds': wholeCandidateIds,
        'wholePreviewId': wholePreviewId,
        'shotCandidateIds': {
          for (final e in shotCandidateIds.entries) '${e.key}': e.value,
        },
        if (wholeTrimStarts.isNotEmpty)
          'wholeTrimStarts': {
            for (final e in wholeTrimStarts.entries) '${e.key}': e.value,
          },
        if (shotTrimStarts.isNotEmpty)
          'shotTrimStarts': {
            for (final e in shotTrimStarts.entries)
              '${e.key}': {
                for (final t in e.value.entries) '${t.key}': t.value,
              },
          },
        'shotPreviewIds': {
          for (final e in shotPreviewIds.entries) '${e.key}': e.value,
        },
      };

  /// 宽松解析：任务 JSON 是历史数据，**任何畸形都不许抛异常**。
  ///
  /// 本项目出过「任务 JSON 少一个字段就整条从列表静默消失」的事故：
  /// [RenewTask.fromJson] 一旦抛出，findAll 会跳过整个文件，用户看到的是
  /// 「我的任务不见了」。因此这里逐级降级——结构不是对象返回 null（由调用方
  /// 决定补位），mode 无法识别退回保留原片，单个候选 id / 镜头键畸形只跳过
  /// 它自己。
  static UnitReplacement? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final mode = _parseMode(raw['mode']);
    switch (mode) {
      case ReplacementMode.keepOriginal:
        return UnitReplacement.keepOriginal();
      case ReplacementMode.whole:
        return UnitReplacement.whole(_intList(raw['wholeCandidateIds']),
            trimStarts: _previewMap(raw['wholeTrimStarts']),
            previewId: raw['wholePreviewId'] is int
                ? raw['wholePreviewId'] as int
                : null);
      case ReplacementMode.perShot:
        return UnitReplacement.perShot(_shotMap(raw['shotCandidateIds']),
            trimStarts: _trimMap(raw['shotTrimStarts']),
            previewIds: _previewMap(raw['shotPreviewIds']));
    }
  }

  /// 镜头下标 → 预览候选 id。畸形条目跳过——预览指向丢了会退回第一个，
  /// 不是什么要紧事，没必要为它把整条方案废掉
  /// 取段起点表：`{"镜头下标": {"候选 id": 起点毫秒}}`。
  /// 任何一层读不懂就当那一层没有——一个坏字段不该让整条方案作废
  static Map<int, Map<int, int>> _trimMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <int, Map<int, int>>{};
    for (final e in raw.entries) {
      final shot = int.tryParse('${e.key}');
      if (shot == null) continue;
      final inner = _previewMap(e.value);
      if (inner.isNotEmpty) out[shot] = inner;
    }
    return out;
  }

  static Map<int, int> _previewMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <int, int>{};
    for (final entry in raw.entries) {
      final shot = int.tryParse('${entry.key}');
      final id = entry.value;
      if (shot == null || id is! int) continue;
      out[shot] = id;
    }
    return out;
  }

  static ReplacementMode _parseMode(Object? raw) {
    final name = raw is String ? raw : null;
    final matched =
        ReplacementMode.values.firstWhereOrNull((m) => m.name == name);
    if (matched != null) return matched;
    if (name != null) {
      AppLog.warn('替换模式「$name」无法识别，按保留原片处理');
    }
    return ReplacementMode.keepOriginal;
  }

  static List<int> _intList(Object? raw) => raw is! List
      ? const []
      : [
          for (final v in raw)
            if (v is int) v,
        ];

  static Map<int, List<int>> _shotMap(Object? raw) {
    if (raw is! Map) return const {};
    final parsed = <int, List<int>>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final index = key is int ? key : int.tryParse('$key');
      if (index == null || index < 0) {
        AppLog.warn('替换方案里的镜头下标「$key」无法识别，已跳过该镜头');
        continue;
      }
      parsed[index] = _intList(entry.value);
    }
    return parsed;
  }

  @override
  bool operator ==(Object other) =>
      other is UnitReplacement &&
      other.mode == mode &&
      const ListEquality<int>().equals(other.wholeCandidateIds, wholeCandidateIds) &&
      const MapEquality<int, List<int>>(values: ListEquality<int>())
          .equals(other.shotCandidateIds, shotCandidateIds);

  @override
  int get hashCode => Object.hash(
        mode,
        Object.hashAll(wholeCandidateIds),
        Object.hashAllUnordered(
          shotCandidateIds.entries
              .map((e) => Object.hash(e.key, Object.hashAll(e.value))),
        ),
      );
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

  /// 精确统计的上限。超过它就没必要再算下去：界面上写「1.15 万亿条」既不可读，
  /// 也不比一句「远超上限」更有用，而继续乘下去会溢出成负数。
  static const int preciseCeiling = 1000000;

  /// 精确组合数（[combinationCount] 一超限就停在哨兵值，说不出「超了多少」）。
  ///
  /// 同样带饱和：超过 [preciseCeiling] 时停在该值，并由
  /// [overflowsPreciseCount] 如实标记「这个数不是真值」。
  int get preciseCombinationCount {
    var total = 1;
    for (final unit in units) {
      final f = unit.factor;
      if (f <= 0) continue;
      if (total > preciseCeiling ~/ f) return preciseCeiling;
      total *= f;
      if (total >= preciseCeiling) return preciseCeiling;
    }
    return total;
  }

  /// 组合数是否已大到无法精确统计（界面据此改说「远超上限」）
  bool get overflowsPreciseCount => preciseCombinationCount >= preciseCeiling;

  /// 因子最大的单元下标——超限时用来告诉用户「该从哪儿减」。
  /// 全是保留原片（因子都为 1）时返回 null：指着一个没得减的单元让用户减，
  /// 只会让人更困惑。
  int? get largestFactorUnitIndex {
    int? best;
    var bestFactor = 1;
    for (var i = 0; i < units.length; i++) {
      final f = units[i].factor;
      if (f > bestFactor) {
        bestFactor = f;
        best = i;
      }
    }
    return best;
  }

  /// 是否一条替换都没设置（组合数为 1 意味着导出结果与原片相同）
  bool get isEmpty => units.every((u) => !u.producesReplacement);
}
