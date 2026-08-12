import '../../core/editing/blank_unit_ops.dart';
import '../../core/models/semantic_unit.dart';

/// 审片台底部状态摘要（纯函数，便于穷举各种打标覆盖情况）。
///
/// [hasTagGroups] 表示这条任务在新建时选过标签组。区分它是为了不冤枉旧任务：
/// 旧任务本来就没选过组，摘要里提「未打标」只是噪音；而选过组却一个标签都没
/// 拿到，说明打标那一步出了问题，必须让用户看见，不能假装打标完成。
String workbenchSummaryText({
  required List<SemanticUnit> units,
  required int durationMs,
  required bool dirty,
  required bool hasTagGroups,

  /// 替换之后成片有多长。与 [durationMs]（原片时长）不同时两个都写出来——
  /// 时间线画的已经是成片了，这一行还只报原片时长，用户会以为哪儿算错了
  int? composedMs,

  /// 空白任务：没有原片，分子是手动排的。这时**时长只统计已挑到素材的
  /// 分子**——没挑的那些在时间线上占的是个占位长度，把它算进总时长等于
  /// 给用户一个假数字，他会照着它去规划片长
  BlankFillStat? blankFill,
}) {
  if (blankFill != null) {
    return _blankSummary(units, blankFill, dirty);
  }
  final totalShots = units.fold<int>(0, (sum, u) => sum + u.shots.length);
  final durationSec = (durationMs / 1000).toStringAsFixed(1);
  final changed = composedMs != null &&
      composedMs > 0 &&
      (composedMs - durationMs).abs() >= 100;
  final duration = changed
      ? '时长 ${(composedMs / 1000).toStringAsFixed(1)}s'
          '（原片 ${durationSec}s）'
      : '时长 ${durationSec}s';
  final base =
      '共 ${units.length} 个台词语义单元 · $totalShots 个视觉镜头 · $duration';
  return '$base${_taggingPart(units, totalShots, hasTagGroups)}'
      // 工作台里每次改动都直接落库，没有「未保存」这回事。这里曾经写
      // 「有未保存的修改」，会让用户去找一个不存在的保存按钮。
      '${dirty ? ' · 已自动保存' : ''}';
}

/// 空白任务的摘要：说清「填了多少、还差多少」，不提原片也不提镜头
String _blankSummary(
    List<SemanticUnit> units, BlankFillStat fill, bool dirty) {
  final seconds = (fill.filledMs / 1000).toStringAsFixed(1);
  final untagged = units.where((u) => u.tags.isEmpty).length;
  final parts = <String>[
    '共 ${units.length} 个分子',
    fill.filledCount == 0
        ? '一条素材都还没挑'
        : '已填 ${fill.filledCount} 个共 ${seconds}s',
    if (fill.emptyCount > 0) '还有 ${fill.emptyCount} 个没填',
    if (untagged > 0) '$untagged 个还没打标签',
    if (dirty) '已自动保存',
  ];
  return parts.join(' · ');
}

String _taggingPart(
    List<SemanticUnit> units, int totalShots, bool hasTagGroups) {
  final taggedUnits = units.where((u) => u.tags.isNotEmpty).length;
  final taggedShots = units.fold<int>(
      0, (sum, u) => sum + u.shots.where((s) => s.tags.isNotEmpty).length);
  if (taggedUnits == 0 && taggedShots == 0) {
    return hasTagGroups ? ' · 未获得标签（打标未完成，可重新分析）' : '';
  }
  final coverage = '单元 $taggedUnits/${units.length} · '
      '镜头 $taggedShots/$totalShots';
  // 只有两层都打满才叫「完成」。曾经只要任一层有标签就写「两层打标完成」，
  // 于是真机上出现过「两层打标完成（单元 6/6 · 镜头 0/52）」——括号里明明
  // 白白写着一个都没打，前面却说完成了。
  final done = taggedUnits == units.length && taggedShots == totalShots;
  return done ? ' · 两层打标完成（$coverage）' : ' · 打标覆盖 $coverage';
}
