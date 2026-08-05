
import '../log/app_log.dart';
import 'boundary_reviewer.dart';
import 'frame_signal_extractor.dart';
import 'shot_boundary_detector.dart';

/// 视觉镜头切点的完整求解：采信号 → 双判据判定 → 灰区画面复核。
///
/// 把三段串起来单独成类，是为了让 [AnalysisPipeline] 只依赖「给我切点」这
/// 一件事，而这里的每一段都能独立替换与测试。
class ShotBoundaryFinder {
  final FrameSignalExtractor extractor;
  final ShotBoundaryDetector detector;

  /// null 表示不做画面复核（凭据未配置时）——此时灰区切点**全部保留**
  final BoundaryReviewer? reviewer;

  const ShotBoundaryFinder({
    required this.extractor,
    this.detector = const ShotBoundaryDetector(),
    this.reviewer,
  });

  Future<List<int>> find({
    required String videoPath,
    required String taskId,
    required double fps,
  }) async {
    // 这一步内部分两段：本地 ffmpeg 采信号、云端灰区复核。两段的耗时差着
    // 一个数量级（实测 19s vs 109s），合成一个数字看不出瓶颈在哪
    final extractWatch = Stopwatch()..start();
    final signals = await extractor.extract(videoPath, taskId: taskId);
    extractWatch.stop();
    final candidates = detector.detect(signals);

    final reviewWatch = Stopwatch()..start();
    final reviewed = await _review(
        videoPath: videoPath, taskId: taskId, fps: fps, candidates: candidates);
    reviewWatch.stop();
    AppLog.info('镜头切点：采信号 '
        '${(extractWatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s、'
        '灰区复核 '
        '${(reviewWatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'
        '（送检 ${reviewer == null ? 0 : reviewer!.pick(candidates).length} 个，'
        '全并发）');
    lastDetails = Map.unmodifiable({for (final c in reviewed) c.ms: c});
    return List.unmodifiable([for (final c in reviewed) c.ms]);
  }

  /// 最近一次求解的判定明细（切点毫秒 → 候选）。构树时据此把画面差异分数
  /// 与判定结论落到镜头上，供事后回看「这一刀是怎么定出来的」。
  static Map<int, ShotBoundaryCandidate> lastDetails = const {};

  Future<List<ShotBoundaryCandidate>> _review({
    required String videoPath,
    required String taskId,
    required double fps,
    required List<ShotBoundaryCandidate> candidates,
  }) async {
    final r = reviewer;
    if (r == null) return candidates;
    final pending = r.pick(candidates);
    if (pending.isEmpty) return candidates;

    // 全并发送检。此前限 4 路，21 个候选要 84 秒——而实测本账号并发 24 的
    // 视觉调用零限流，那 84 秒纯粹是自己给自己排的队
    final verdicts = <int, BoundaryVerdict>{};
    await Future.wait([
      for (final c in pending)
        r
            .reviewOne(
                videoPath: videoPath, candidate: c, fps: fps, taskId: taskId)
            .then((v) => verdicts[c.ms] = v),
    ]);

    final dropped =
        verdicts.values.where((v) => v == BoundaryVerdict.same).length;
    AppLog.info('画面复核：送检 ${pending.length} 个灰区切点，'
        '判为同一镜头 $dropped 个（已撤销），其余保留');
    return applyVerdicts(candidates, verdicts);
  }
}
