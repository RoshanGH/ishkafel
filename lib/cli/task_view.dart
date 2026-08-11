import '../core/models/renew_task.dart';
import '../core/models/semantic_unit.dart';

/// 任务的 JSON 视图——**给事实，不给结论**。
///
/// 每段多长、台词是什么、打了哪些标签、哪些镜头挑过素材，都如实摆出来；
/// 「该挑哪个」是调用方的判断（见 spec 第一节：软件提供事实与保护，
/// skill 提供方法论）。
///
/// `analyzed` 与 `units: null` 是两件事：还没分析完就是 null，**不能拿空数组
/// 冒充**「分析完了但没有单元」——调用方据此决定是等着还是往下走。
Map<String, dynamic> taskToJson(RenewTask task) {
  final units = task.units;
  return {
    'id': task.id,
    'name': task.name,
    'status': task.status.name,
    'sourcePath': task.sourcePath,
    'durationMs': task.videoInfo?.duration.inMilliseconds,
    'fps': task.videoInfo?.fps,
    'analyzed': units != null,
    // 分析出错时把原因带出来：调用方要能分辨「还在跑」和「跑挂了」
    'analysisError': task.analysisError,
    'units': units == null ? null : [for (final u in units) _unitToJson(u)],
    'exports': [
      for (final e in task.exports)
        {
          'at': e.at.toIso8601String(),
          'total': e.total,
          'succeeded': e.succeeded,
          'outputDir': e.outputDir,
        },
    ],
  };
}

Map<String, dynamic> _unitToJson(SemanticUnit unit) => {
      'index': unit.index,
      'startMs': unit.startMs,
      'endMs': unit.endMs,
      'durationMs': unit.endMs - unit.startMs,
      'transcript': unit.transcript,
      'tags': unit.tags,
      'shots': [
        for (var i = 0; i < unit.shots.length; i++)
          {
            'index': i,
            'startMs': unit.shots[i].startMs,
            'endMs': unit.shots[i].endMs,
            'durationMs': unit.shots[i].endMs - unit.shots[i].startMs,
            'description': unit.shots[i].description,
            'tags': unit.shots[i].tags,
          },
      ],
    };
