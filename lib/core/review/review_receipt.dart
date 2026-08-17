import '../replacement/replacement_plan.dart';

/// 人审核挑好的候选：这一层是**确定的剔除规则**。
///
/// 审核完一切回到主流程：剔除在确认那一刻落进任务，之后
/// `ishkafel task <id>` 里的方案**就是**最终结果——没有回执、没有第二个
/// 真相来源。Agent 想知道剔了哪几条，拿自己提交过的方案和现状一比就有；
/// 人确认没确认，由人开口告诉它（等不等、等多久是人和 Agent 之间的策略，
/// 软件只提供审核功能，不当流程裁判）

/// 一条候选的去留。[shot] 为 null 表示整体替换的候选，否则是镜头替换
class ReviewDecision {
  final int unit;
  final int? shot;
  final int material;
  final bool keep;

  const ReviewDecision({
    required this.unit,
    required this.shot,
    required this.material,
    required this.keep,
  });

  Map<String, dynamic> toJson() =>
      {'unit': unit, 'shot': shot, 'material': material, 'keep': keep};

  static ReviewDecision? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final unit = raw['unit'];
    final material = raw['material'];
    if (unit is! int || material is! int) return null;
    return ReviewDecision(
      unit: unit,
      shot: raw['shot'] is int ? raw['shot'] as int : null,
      material: material,
      keep: raw['keep'] != false,
    );
  }
}

/// 一个待审的位置：这个单元/镜头挑了这条素材
class ReviewItem {
  final int unit;

  /// null = 整体替换的候选
  final int? shot;
  final int material;

  const ReviewItem(
      {required this.unit, required this.shot, required this.material});
}

/// 把方案里所有挑过的候选摊平成待审清单（保留原片的不列）
List<ReviewItem> collectReviewItems(List<UnitReplacement> replacements) {
  final items = <ReviewItem>[];
  for (var u = 0; u < replacements.length; u++) {
    final r = replacements[u];
    for (final id in r.wholeCandidateIds) {
      items.add(ReviewItem(unit: u, shot: null, material: id));
    }
    final shots = r.shotCandidateIds.keys.toList()..sort();
    for (final s in shots) {
      for (final id in r.shotCandidateIds[s]!) {
        items.add(ReviewItem(unit: u, shot: s, material: id));
      }
    }
  }
  return items;
}

/// 按决定剔除候选。规则刻意保守：
/// - **没被提到的候选一律保留**——回执少一条不能变成隐式剔除
/// - 决定引用了不存在的位置就忽略该条，不炸也不误伤别人
/// - 某个位置全被剔除也如实执行（等同保留原片）
List<UnitReplacement> applyReviewDecisions(
  List<UnitReplacement> replacements,
  List<ReviewDecision> decisions,
) {
  final dropWhole = <int, Set<int>>{};
  final dropShot = <int, Map<int, Set<int>>>{};
  for (final d in decisions) {
    if (d.keep) continue;
    if (d.unit < 0 || d.unit >= replacements.length) continue;
    if (d.shot == null) {
      (dropWhole[d.unit] ??= {}).add(d.material);
    } else {
      ((dropShot[d.unit] ??= {})[d.shot!] ??= {}).add(d.material);
    }
  }

  return [
    for (var u = 0; u < replacements.length; u++)
      _pruned(replacements[u], dropWhole[u] ?? const {},
          dropShot[u] ?? const {}),
  ];
}

UnitReplacement _pruned(
  UnitReplacement r,
  Set<int> dropWhole,
  Map<int, Set<int>> dropShot,
) {
  if (dropWhole.isEmpty && dropShot.isEmpty) return r;
  switch (r.mode) {
    case ReplacementMode.keepOriginal:
      return r;
    case ReplacementMode.whole:
      return UnitReplacement.whole(
        [
          for (final id in r.wholeCandidateIds)
            if (!dropWhole.contains(id)) id,
        ],
        previewId: r.wholePreviewId,
      );
    case ReplacementMode.perShot:
      return UnitReplacement.perShot(
        {
          for (final e in r.shotCandidateIds.entries)
            e.key: [
              for (final id in e.value)
                if (!(dropShot[e.key]?.contains(id) ?? false)) id,
            ],
        },
        previewIds: r.shotPreviewIds,
      );
  }
}
