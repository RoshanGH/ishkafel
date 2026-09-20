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

  /// 从毫秒区间取帧区间，**并把段头补成对称的**。
  ///
  /// **下游凡是要把毫秒区间变成帧区间的，一律走这里。** 裸调
  /// [FrameSpan.fromMs]（或 `frameIndex`）会丢掉段头对称，相邻段就会共享帧
  /// ——那正好废掉整条轴选「帧」而不是「毫秒」的唯一理由。
  ///
  /// [FrameSpan.fromMs] 只在段尾做了「回退到严格早于 endMs」的修正，段头是
  /// 直接四舍五入。边界不落在帧点上时（整体替换的时长直接来自素材的
  /// ffprobe 结果，根本不过帧对齐这一步；ASR 的词级时间戳同理），舍出来的
  /// 那一帧的时间戳可能早于 [startMs]，于是它**同时被判给前一段的尾帧和
  /// 后一段的头帧**——真机数据 5237ms 的边界上，帧 157 就被两个单元同时
  /// 认领；任务 #1 的 487 对相邻词里有 375 对共享了同一帧。
  ///
  /// **相邻段不共享任何一帧是这个类存在的唯一理由**，所以它得自己守住。
  /// 为什么不去改 `FrameSpan.fromMs`：它还被播放器逐帧步进、时间线编辑、
  /// mpv 播放用着，动它要跑预览体检（`scripts/preview_health.sh`）。
  ///
  /// 守这条纪律的架构测试在
  /// `test/architecture/subtitle_ms_to_frames_one_path_test.dart`。
  FrameSpan spanOfMs(int startMs, int endMs) {
    final raw = FrameSpan.fromMs(startMs, endMs, _fps);
    var first = raw.first;
    while (msOfFrame(first, _fps) < startMs) {
      first++;
    }
    return FrameSpan(
        first: first, last: raw.last < first ? first : raw.last, fps: _fps);
  }

  FrameSpan unitSpan(int unitIndex) {
    final start = timeline.startOf(unitIndex);
    return spanOfMs(start, start + timeline.durationOf(unitIndex));
  }

  /// 这一镜占成片的哪几帧。**整块段落返回 null**——那一段整个换成了另一条
  /// 素材，原片的镜头切分在成片里已经不存在，编一个数出来是假精度
  FrameSpan? shotSpan(int unitIndex, int shotIndex) {
    final start = timeline.composedShotStart(unitIndex, shotIndex);
    final end = timeline.composedShotEnd(unitIndex, shotIndex);
    if (start == null || end == null) return null;
    return spanOfMs(start, end);
  }

  /// 帧号 → `00:00:20:12`（时:分:秒:帧）。对标剪映 / FCP 的读法。
  ///
  /// **整数取模，不要用浮点连乘再四舍五入去凑。** 原来写成
  /// `frame ~/ _fps` 配 `(totalSeconds * _fps).round()`：这两个公式在非整数
  /// 帧率下互不自洽，29.97 下几乎每一秒的最后一帧都会算出 `ff == 30` 这种
  /// 不合法的帧号（`tc(1798)` 印出 `00:00:59:30`）。
  ///
  /// 非整数帧率的时间码惯例是按**标称帧率**取模（29.97 的标称帧率是 30），
  /// 这样帧号恒落在 `[0, 标称)` 内，不会溢出也不会变负。
  String tc(int frame) {
    final nominal = _fps.round().clamp(1, 1000);
    final totalSeconds = frame ~/ nominal;
    final ff = frame % nominal;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(totalSeconds ~/ 3600)}:${two((totalSeconds % 3600) ~/ 60)}:'
        '${two(totalSeconds % 60)}:${two(ff)}';
  }
}
