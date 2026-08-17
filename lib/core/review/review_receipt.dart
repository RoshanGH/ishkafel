import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../replacement/replacement_plan.dart';

/// 人审核 Agent 挑的候选：这一层是**固定的回执格式**与**确定的应用规则**。
///
/// Agent 现造审核页的问题就在这两处：回执格式每次现编、剔除逻辑每次现写，
/// 换个 Agent 换个会话就变。把它们钉进软件，任何 Agent 走到审核这一步，
/// 拿到的都是同一份契约：
///
/// - GUI 审核完把 [ReviewReceipt] 写到 `<dataDir>/reviews/<task>.json`
/// - Agent 用 `ishkafel review-result <task>` 取回执
/// - 剔除已经由 GUI 在确认那一刻落进任务（[applyReviewDecisions]），
///   Agent 不需要也不应该再改一遍方案

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

class ReviewReceipt {
  final DateTime reviewedAt;
  final List<ReviewDecision> decisions;

  const ReviewReceipt({required this.reviewedAt, required this.decisions});

  int get keptCount => decisions.where((d) => d.keep).length;
  int get droppedCount => decisions.length - keptCount;

  Map<String, dynamic> toJson() => {
        'reviewedAt': reviewedAt.toIso8601String(),
        'decisions': [for (final d in decisions) d.toJson()],
      };

  static ReviewReceipt? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['reviewedAt']}');
    if (at == null) return null;
    return ReviewReceipt(
      reviewedAt: at,
      decisions: [
        for (final item in (raw['decisions'] as List? ?? []))
          ?ReviewDecision.tryFromJson(item),
      ],
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

File reviewReceiptFile(Directory dataDir, String taskId) =>
    File(p.join(dataDir.path, 'reviews', '$taskId.json'));

void saveReviewReceipt(
    Directory dataDir, String taskId, ReviewReceipt receipt) {
  final file = reviewReceiptFile(dataDir, taskId);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode(receipt.toJson()));
}

ReviewReceipt? readReviewReceipt(Directory dataDir, String taskId) {
  final file = reviewReceiptFile(dataDir, taskId);
  if (!file.existsSync()) return null;
  try {
    return ReviewReceipt.tryFromJson(jsonDecode(file.readAsStringSync()));
  } catch (_) {
    return null; // 文件坏了当没审核过，别炸
  }
}
