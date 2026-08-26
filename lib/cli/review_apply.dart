import '../core/review/review_receipt.dart';

/// Agent 替人剔除候选：**人看着卡片墙说「这几条删掉」，它去动手**。
///
/// 校验规则与界面确认走的 [applyReviewDecisions] 刻意相反：
///
/// - 界面那条**宽松**——回执里少提一条不能变成隐式剔除，位置对不上就忽略
/// - 这里**严格**——是 Agent 主动报的编号，对不上就是它错了。静默忽略的话，
///   人说「删掉第 3 条」，它写错编号却报成功，人会以为删掉了
///
/// 一次把全部问题报完（整批拒绝），不是报一条改一条。
List<String> validateReviewSubmission({
  required List<ReviewItem> items,
  required List<ReviewDecision> decisions,
}) {
  // 空提交不等于「什么都不改」：多半是编号没解析出来，当成成功更糟
  if (decisions.isEmpty) return const ['一条决定都没有——要动哪几条候选？'];

  final known = {for (final i in items) _key(i.unit, i.shot, i.material)};
  final seen = <String, bool>{};
  final issues = <String>[];
  for (var n = 0; n < decisions.length; n++) {
    final d = decisions[n];
    final key = _key(d.unit, d.shot, d.material);
    final where = _human(d.unit, d.shot, d.material);
    if (!known.contains(key)) {
      issues.add('第 ${n + 1} 条：任务里没有 $where 这个候选。'
          '先 ishkafel review list <任务> 看现在有哪些');
      continue;
    }
    final before = seen[key];
    if (before != null && before != d.keep) {
      issues.add('第 ${n + 1} 条：$where 前后说法不一致（一处要留、一处要删）');
      continue;
    }
    seen[key] = d.keep;
  }
  return issues;
}

/// 解析 `--items` 的简写：`unit:shot:material`，逗号分隔。
/// [shot] 用 `-` 表示整体替换的候选（那一层没有镜头号）。
///
/// 解析不出来就**点名那一段**并整批不执行——不猜、不跳过。
({List<ReviewDecision> decisions, List<String> issues}) parseReviewItems(
  String raw, {
  required bool keep,
}) {
  final pieces = [
    for (final piece in raw.split(',')) piece.trim(),
    ].where((s) => s.isNotEmpty).toList();
  if (pieces.isEmpty) {
    return (decisions: const [], issues: const ['没给要动的候选（--items）']);
  }
  final decisions = <ReviewDecision>[];
  final issues = <String>[];
  for (final piece in pieces) {
    final parts = piece.split(':');
    final unit = parts.length == 3 ? int.tryParse(parts[0].trim()) : null;
    final material = parts.length == 3 ? int.tryParse(parts[2].trim()) : null;
    final shotRaw = parts.length == 3 ? parts[1].trim() : '';
    final shot = (shotRaw == '-' || shotRaw.isEmpty)
        ? null
        : int.tryParse(shotRaw);
    if (unit == null || material == null || (shot == null && shotRaw != '-' &&
        shotRaw.isNotEmpty)) {
      issues.add('看不懂「$piece」。格式是 单元:镜头:素材，'
          '整体替换的候选镜头位写 `-`，例如 0:-:12345 或 1:2:678');
      continue;
    }
    decisions.add(ReviewDecision(
        unit: unit, shot: shot, material: material, keep: keep));
  }
  return (decisions: decisions, issues: issues);
}

String _key(int unit, int? shot, int material) => '$unit/${shot ?? '-'}/$material';

String _human(int unit, int? shot, int material) => shot == null
    ? '第 ${unit + 1} 段整体替换的素材 $material'
    : '第 ${unit + 1} 段第 ${shot + 1} 镜的素材 $material';
