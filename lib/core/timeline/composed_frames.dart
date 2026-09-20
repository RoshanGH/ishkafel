import '../editing/frame_time.dart';
import '../export/composed_timeline.dart';
import '../time/rational.dart';

/// **全软件唯一的排序基准：成片帧轴。**
///
/// 所有「先后、位置、多长」对外一律用它；原片毫秒、素材内毫秒、镜头内毫秒
/// 全部降格为**取材信息**（从哪个文件的哪一段取画面），**永不参与排序**。
///
/// **为什么是成片，不是原片**：手动添加的单元在原片轴上根本没有位置
/// （`SemanticUnit.hasSource == false`）。拿原片轴当基准，它们只能排在末尾
/// 或者编一个假坐标——而人恰恰是把它们插在中间的。整体替换同理：它改变
/// 时长，原片轴上后面每一段的位置在成片里都已经不成立。
///
/// **为什么是帧，不是毫秒**：「这个字属于哪一镜」是边界问题。毫秒上相邻
/// 两段共享边界（前一段 `endMs` == 后一段 `startMs`），那一刻同时属于两段，
/// 回答不了；[FrameSpan] 是闭区间，相邻段不共享任何一帧。
/// 另外 29.97 在毫秒上和 30 分不开（`round(1000/fps)` 对两者都是 33ms）。
///
/// **工程帧率锁死，不跟着导出走**：导出规格可改（`export --fps`），
/// 轴跟着它变就不「恒定」了。导出成别的帧率只在导出那一步映射一次。
class ComposedFrames {
  final ComposedTimeline timeline;

  /// 工程帧率
  final Rational fps;

  /// 这个帧率哪来的：`original` = 原片的，`default` = 拿不到，退到了 30。
  /// **退化值必须说出来**——它和真值长得一模一样，不说就是静默降级
  final String fpsSource;

  const ComposedFrames._(this.timeline, this.fps, this.fpsSource);

  static ComposedFrames of({
    required ComposedTimeline timeline,
    Rational? fps,
  }) =>
      ComposedFrames._(
          timeline, fps ?? Rational.fps30, fps == null ? 'default' : 'original');

  double get _fps => fps.num / fps.den;

  int get totalFrames => timeline.totalMs <= 0
      ? 0
      : FrameSpan.fromMs(0, timeline.totalMs, _fps).frameCount;

  /// 某个成片毫秒落在第几帧
  int frameAt(int composedMs) => frameIndex(composedMs, _fps);

  FrameSpan unitSpan(int unitIndex) {
    final start = timeline.startOf(unitIndex);
    return FrameSpan.fromMs(start, start + timeline.durationOf(unitIndex), _fps);
  }

  /// 这一镜占成片的哪几帧。**整块段落返回 null**——那一段整个换成了另一条
  /// 素材，原片的镜头切分在成片里已经不存在，编一个数出来是假精度
  FrameSpan? shotSpan(int unitIndex, int shotIndex) {
    final start = timeline.composedShotStart(unitIndex, shotIndex);
    final end = timeline.composedShotEnd(unitIndex, shotIndex);
    if (start == null || end == null) return null;
    return FrameSpan.fromMs(start, end, _fps);
  }

  /// 帧号 → `00:00:20:12`（时:分:秒:帧）。对标剪映 / FCP 的读法
  String tc(int frame) {
    final perSecond = _fps <= 0 ? 1 : _fps;
    final totalSeconds = frame ~/ perSecond;
    final ff = frame - (totalSeconds * perSecond).round();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(totalSeconds ~/ 3600)}:${two((totalSeconds % 3600) ~/ 60)}:'
        '${two(totalSeconds % 60)}:${two(ff < 0 ? 0 : ff)}';
  }
}
