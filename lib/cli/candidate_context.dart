import '../core/models/renew_task.dart';
import '../core/models/semantic_unit.dart';

/// 挑这个镜头的素材时，调用方需要知道的**周边事实**。
///
/// 只给「这个镜头 2.8 秒、标签是厨房清洁」，很容易挑出每一个都合规、连起来
/// 很怪的组合——人挑的时候是有整体感的：知道这里是开箱、那里是演示效果，
/// 所以不会在「擦冰箱」后面接一个同类的空镜。
///
/// **软件只负责把这些事实摆出来。**「要和前后顺不顺」「同批微调版要挑差异
/// 大的」是方法论，写在给 Agent 的 skill 里，不硬编码进这里
/// （见 spec 第一节：软件提供事实与保护，skill 提供方法论）。
Map<String, dynamic> shotContext({
  required RenewTask task,
  required int unitIndex,
  required int shotIndex,
}) {
  final units = task.units ?? const <SemanticUnit>[];
  final unit = units[unitIndex];
  final shots = unit.shots;
  final shot = shots[shotIndex];

  return {
    'unitIndex': unitIndex,
    // 这一段的身份。**下标是位置、uid 才是身份**——日志按 uid 记，
    // 照着日志回来挑素材时要对得上是不是同一段
    'unitUid': unit.uid,
    'shotIndex': shotIndex,
    // 变速倍率靠它算：候选比坑位长就要加速，超出可变速区间就不能用
    'slotMs': shot.endMs - shot.startMs,
    'description': shot.description,
    'tags': shot.tags,
    'unitTranscript': unit.transcript,
    'unitTags': unit.tags,
    'previous':
        shotIndex == 0 ? null : _neighbour(task, unitIndex, shotIndex - 1),
    'next': shotIndex >= shots.length - 1
        ? null
        : _neighbour(task, unitIndex, shotIndex + 1),
  };
}

Map<String, dynamic> _neighbour(RenewTask task, int unitIndex, int shotIndex) {
  final shot = task.units![unitIndex].shots[shotIndex];
  return {
    'shotIndex': shotIndex,
    'description': shot.description,
    'tags': shot.tags,
    'durationMs': shot.endMs - shot.startMs,
    // 相邻镜头已经挑了什么：组方案时要避开和它雷同的素材
    'pickedMaterialIds': _pickedFor(task, unitIndex, shotIndex),
  };
}

/// 没挑过就是空列表，不是 null——调用方不必为此做两种判断
List<int> _pickedFor(RenewTask task, int unitIndex, int shotIndex) {
  final replacements = task.replacementsFor(task.units ?? const []);
  if (unitIndex < 0 || unitIndex >= replacements.length) return const [];
  return replacements[unitIndex].shotCandidateIds[shotIndex] ?? const [];
}
