import 'frame_signal.dart';

/// 一个候选切点的把握程度
enum BoundaryConfidence {
  /// 两项指标都过高线：直接采用，不必再看
  confirmed,

  /// 落在灰区：像切换但也可能只是画面里动得厉害，交给复核环节看一眼
  uncertain,
}

/// 一个候选的视觉镜头切点
class ShotBoundaryCandidate {
  final int ms;
  final BoundaryConfidence confidence;

  /// 保留原始指标，复核环节与排障都要用
  final double sceneScore;
  final double histDistance;

  const ShotBoundaryCandidate({
    required this.ms,
    required this.confidence,
    required this.sceneScore,
    required this.histDistance,
  });

  bool get isConfirmed => confidence == BoundaryConfidence.confirmed;

  @override
  String toString() =>
      'Boundary(${ms}ms ${confidence.name} scene=${sceneScore.toStringAsFixed(3)} '
      'hist=${histDistance.toStringAsFixed(3)})';
}

/// 视觉镜头切点检测的判定门槛。
///
/// 取值依据（两条真实素材 + 9 个人工核对过的样本，见
/// docs/plans/2026-08-01-镜头切分优化.md）：
/// - 真实切换的直方图距离在 0.49~0.57，最高的一次**误检**（手在画面里快速
///   移动）只有 0.374 —— 中间有明显空档。
/// - 同样这批样本上，scene 分数真假只差 0.04（0.339 vs 0.299），判别力
///   远不如直方图。因此高线以直方图为主、scene 为辅。
class BoundaryThresholds {
  /// 直方图距离高线：过了就直接确认
  final double histHigh;

  /// 直方图距离低线：低于它连候选都不算。
  ///
  /// 0.20 是拿两条真实素材扫出来的上限：再高就开始把 **AI 复核认可过的真切点**
  /// 挡在候选之外（0.22 时视频一漏 1 个、视频二把唯一那个漏光）。
  /// 从 0.16 提到 0.20 能少送检 14~26%，且不影响任何已知真切点。
  ///
  /// 顺带记一笔：这一版扫描证明「送检多」不是阈值设松了——**真切点确实分布
  /// 在灰区里**，砍不动。压缩复核时间只能靠并发。
  final double histLow;

  /// scene 分数高线：画面结构剧烈突变，同样直接确认
  final double sceneHigh;

  /// scene 分数低线
  final double sceneLow;

  /// 最短镜头时长。比这更近的两个切点合并成一个——短视频广告里几帧长的
  /// 「镜头」没有产品意义，只会让用户多点几次合并。
  final int minShotMs;

  const BoundaryThresholds({
    this.histHigh = 0.44,
    this.histLow = 0.20,
    this.sceneHigh = 0.42,
    this.sceneLow = 0.10,
    this.minShotMs = 400,
  });
}

/// 从逐帧信号推导视觉镜头切点（纯函数，可穷举验证）。
///
/// 为什么不只用 ffmpeg 的 `scene` 分数：它是**相邻帧差分**，衡量的是「动得
/// 多剧烈」而不是「画面内容换没换」。实测手在画面里快速移动能冲到 0.299，
/// 而真实切换是 0.339——两者几乎贴在一起，靠一个阈值分不开。加入颜色直方
/// 图距离才分得开：运动不改变颜色分布，换机位改变。
class ShotBoundaryDetector {
  final BoundaryThresholds thresholds;

  const ShotBoundaryDetector({this.thresholds = const BoundaryThresholds()});

  List<ShotBoundaryCandidate> detect(List<FrameSignal> signals) {
    final t = thresholds;
    final hits = <ShotBoundaryCandidate>[];

    for (final s in signals) {
      final confirmed = s.histDistance >= t.histHigh || s.sceneScore >= t.sceneHigh;
      // 灰区：两项都够得着低线，但谁都没到高线
      final uncertain =
          s.histDistance >= t.histLow && s.sceneScore >= t.sceneLow;
      if (!confirmed && !uncertain) continue;
      hits.add(ShotBoundaryCandidate(
        ms: s.ms,
        confidence: confirmed
            ? BoundaryConfidence.confirmed
            : BoundaryConfidence.uncertain,
        sceneScore: s.sceneScore,
        histDistance: s.histDistance,
      ));
    }

    return _mergeTooClose(hits, t.minShotMs);
  }

  /// 过密的切点合并：保留其中最有把握的那个。
  ///
  /// 优先留 confirmed；同级别时留指标更强的——一次真实切换常常在相邻两三帧
  /// 都触发，留下最强的那一帧才是真正的切换位置。
  static List<ShotBoundaryCandidate> _mergeTooClose(
      List<ShotBoundaryCandidate> hits, int minShotMs) {
    if (hits.isEmpty) return const [];
    final out = <ShotBoundaryCandidate>[hits.first];
    for (final h in hits.skip(1)) {
      final last = out.last;
      if (h.ms - last.ms >= minShotMs) {
        out.add(h);
        continue;
      }
      if (_strength(h) > _strength(last)) out[out.length - 1] = h;
    }
    return List.unmodifiable(out);
  }

  /// confirmed 一律强于 uncertain；同级比直方图距离（判别力更强的那个指标）
  static double _strength(ShotBoundaryCandidate c) =>
      (c.isConfirmed ? 100 : 0) + c.histDistance;
}
