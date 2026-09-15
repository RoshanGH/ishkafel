import '../log/app_log.dart';
import '../models/semantic_unit.dart';
import '../models/shot.dart';
import '../replacement/unit_base.dart';
import '../time/timecode.dart';
import 'boundary_trace_index.dart';
import 'scene_detector.dart';
import 'shot_boundary_finder.dart';

/// 对**一段的底片**做视觉镜头切分。
///
/// 跟 [AnalysisPipeline] 那次全片切分是同一条链路（采信号 → 双判据 →
/// 灰区画面复核），只是喂进去的视频换成了这一段自己的底片。这些链路本来
/// 就是按文件参数化的，不绑任务原片。
///
/// **切点落在底片自己的时间轴上**，不是在「适配到坑位之后」的片段上——
/// 素材会被裁剪、变速去适配坑位，在适配后的东西上切，一改倍速切点就全飘了。
/// 映射到成片轴是显示与导出那一层的事（见 [ComposedTimeline.composedShotStart]）。
class UnitSegmenter {
  final ShotBoundaryFinder? boundaries;
  final SceneDetector scenes;

  const UnitSegmenter({required this.scenes, this.boundaries});

  /// 一镜至少多长。比这还短的切点不落刀——碎成半秒一格没法看也没法挑
  static const int minShotMs = 500;

  /// 切这一段的底片，返回**单元坐标**下的镜头列表
  /// （`unit.startMs + 底片内偏移`，与 [SemanticUnit.shots] 一贯的约定一致）。
  ///
  /// [taskId] 只用来给中间产物起名，加上单元身份就能和全片那次分开，
  /// 也不影响 `artifactBelongsTo` 按任务清理
  Future<List<Shot>> segment({
    required SemanticUnit unit,
    required UnitBase base,
    required String taskId,
    required double fps,
  }) async {
    final cuts = await _detect(base.path, '${taskId}_u${unit.uid}', fps);
    final shots = shotsFromCuts(
      unit: unit,
      baseDurationMs: base.durationMs,
      cutsMs: cuts,
      fps: fps,
    );
    // **这一刀是怎么定出来的也要记下来**，跟全片切分一样
    // （见 `AnalysisPipeline._withBoundaryTrace`）：画面差异分数、
    // 是直接确认的还是灰区经画面复核保留的。属性面板靠它回看这一刀的依据，
    // 不记的话底片切出来的镜头就比原片切出来的少一样东西
    return _withBoundaryTrace(shots, unit: unit, fps: fps);
  }

  /// 把切点判定明细贴到镜头上。
  ///
  /// 两处对不齐要当心：[ShotBoundaryFinder.lastDetails] 的键是**底片内的
  /// 原始毫秒**，而镜头坐标是「单元起点 + 帧对齐后的偏移」。所以查表前
  /// 既要减回单元起点，键那边也要先对齐（见 [boundaryTracesByFrame]）
  static List<Shot> _withBoundaryTrace(
    List<Shot> shots, {
    required SemanticUnit unit,
    required double fps,
  }) {
    final traces =
        boundaryTracesByFrame(ShotBoundaryFinder.lastDetails, fps);
    if (traces.isEmpty) return shots;
    return List.unmodifiable([
      for (final s in shots)
        if (traces[s.startMs - unit.startMs] case final t?)
          s.copyWith(boundaryTrace: t)
        else
          s,
    ]);
  }

  Future<List<int>> _detect(String videoPath, String key, double fps) async {
    final finder = boundaries;
    if (finder == null) return scenes.detect(videoPath);
    try {
      return await finder.find(videoPath: videoPath, taskId: key, fps: fps);
    } catch (e) {
      // 与全片切分同一条退路：切分结果本身仍有价值，为了「切得更准」
      // 把整段废掉不划算
      AppLog.warn('这一段的镜头切点检测失败，退回基础场景检测：$e');
      return scenes.detect(videoPath);
    }
  }

  /// 把底片内的切点变成单元坐标下的镜头。**纯函数**，方便单测与复算。
  ///
  /// 规则：
  /// - 切点吸到帧上——卡片按帧显示，落在帧缝里人看到的和实际存的会差一帧
  /// - 太靠边或彼此太近的切点丢掉（[minShotMs]）
  /// - 首尾一定补齐：镜头必须无缝盖满这一段，缺一块就是画面缺一块
  static List<Shot> shotsFromCuts({
    required SemanticUnit unit,
    required int baseDurationMs,
    required List<int> cutsMs,
    required double fps,
  }) {
    if (baseDurationMs <= 0) return const [];
    final edges = <int>[0];
    for (final raw in (cutsMs.toList()..sort())) {
      final at = alignToFrame(raw, fps);
      if (at - edges.last < minShotMs) continue;
      if (baseDurationMs - at < minShotMs) continue;
      edges.add(at);
    }
    edges.add(baseDurationMs);
    return List.unmodifiable([
      for (var i = 0; i < edges.length - 1; i++)
        Shot(
          startMs: unit.startMs + edges[i],
          endMs: unit.startMs + edges[i + 1],
        ),
    ]);
  }
}
