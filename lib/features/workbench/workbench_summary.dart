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
}) {
  final totalShots = units.fold<int>(0, (sum, u) => sum + u.shots.length);
  final durationSec = (durationMs / 1000).toStringAsFixed(1);
  final base = '共 ${units.length} 个台词语义单元 · $totalShots 个视觉镜头 · '
      '时长 ${durationSec}s';
  return '$base${_taggingPart(units, totalShots, hasTagGroups)}'
      '${dirty ? ' · 有未保存的修改' : ''}';
}

String _taggingPart(
    List<SemanticUnit> units, int totalShots, bool hasTagGroups) {
  final taggedUnits = units.where((u) => u.tags.isNotEmpty).length;
  final taggedShots = units.fold<int>(
      0, (sum, u) => sum + u.shots.where((s) => s.tags.isNotEmpty).length);
  if (taggedUnits > 0 || taggedShots > 0) {
    return ' · 两层打标完成（单元 $taggedUnits/${units.length} · '
        '镜头 $taggedShots/$totalShots）';
  }
  return hasTagGroups ? ' · 未获得标签（打标未完成，可重新分析）' : '';
}
