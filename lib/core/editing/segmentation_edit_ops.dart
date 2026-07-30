import '../analysis/boundary_snapper.dart';
import '../analysis/providers.dart';
import '../models/semantic_unit.dart';
import '../models/shot.dart';
import 'transcript_splitter.dart';

/// 切分编辑纯函数集：审片台上所有对语义单元/镜头结构的编辑操作都经此模块。
///
/// 所有操作遵循同一流程：帧对齐（snapToFrame）→ 约束校验/裁剪（clamp）→
/// 构造全新列表（绝不原地修改输入）；输入非法时返回 null。
///
/// 每次操作输出必须满足五项不变量（见 [holdsInvariants]）：
/// 1. 单元序列无缝覆盖 `[0, durationMs]`
/// 2. 每个单元内的镜头无缝覆盖该单元范围
/// 3. 单元的首/末镜头边界与单元边界重合
/// 4. 一切边界（单元/镜头）均为帧对齐点
/// 5. 任何单元/镜头时长不小于一帧
abstract final class SegmentationEditOps {
  static const _snapper = BoundarySnapper();

  /// 一帧的毫秒时长（四舍五入）
  static int frameMs(double fps) => (1000 / fps).round();

  static int _snap(int ms, double fps) => _snapper.snapToFrame(ms, fps);

  // 帧序号域算术：30fps 下帧点在 ms 轴非等距（0,33,67,100,133,167…，
  // 间距在 33/34ms 间交替），因此"向内收缩一帧"不能用 ms 域常数偏移
  // （如 ms±frameMs(fps)），必须先转换到帧序号，加减 1 帧后再换算回 ms，
  // 这样得到的边界本身即为合法帧点，clamp 结果必然合法。
  static int _frameIndex(int ms, double fps) => (ms * fps / 1000).round();
  static int _msOfFrame(int idx, double fps) => (idx * 1000 / fps).round();

  /// ms 处的帧点向后收缩一帧得到的合法帧点（用作区间下界）
  static int _frameAfter(int ms, double fps) =>
      _msOfFrame(_frameIndex(ms, fps) + 1, fps);

  /// clamp 上界：返回满足 "endMs - p >= frameMs(fps)"（即收缩后至少留出
  /// 一帧尾段）的最大合法帧点 p。
  ///
  /// 用于替换此前直接用 `_msOfFrame(_frameIndex(endMs, fps) - 1, fps)`
  /// （"单纯回退一帧"）作为区间上界的写法：当 [endMs] 本身是合法帧点时，
  /// 两者结果相同——因为 30fps 下任意两个相邻帧点间距恒为 33/34ms，都
  /// >= frameMs(30)=33，回退一帧天然满足留白约束。但当 [endMs] 非帧点
  /// （真实素材片长的常态，因为 `durationMs` 是外部数据、我们无法选择）
  /// 时，"单纯回退一帧"只是"严格小于 endMs 的最大帧点"，它与 endMs 的
  /// 实际间距可能远小于一帧（最小可至 1ms）——把边界 clamp 到这个上界会
  /// 产出短于一帧的末段，违反"任何单元/镜头时长不小于一帧"这条不变量
  /// （复审实测：30fps 下 durationMs=3984/59987/92253 等真实片长会因此
  /// 触发 `holdsInvariants` 断言失败）。这里改为直接在帧序号域里找"退让
  /// 一帧时长"之后落在的帧点，从根源上保证退让幅度恒 >= 一帧。
  static int _maxBoundaryLeavingOneFrame(int endMs, double fps) {
    final gap = frameMs(fps);
    final threshold = endMs - gap;
    var idx = _frameIndex(threshold, fps);
    if (idx < 0) idx = 0;
    // _msOfFrame 的四舍五入可能让换算回来的 ms 略大于 threshold（超出退让
    // 幅度要求），需要回退校正，确保结果严格满足 endMs - p >= gap
    while (idx > 0 && _msOfFrame(idx, fps) > threshold) {
      idx--;
    }
    return _msOfFrame(idx, fps);
  }

  static List<SemanticUnit> _reindex(List<SemanticUnit> units) => [
        for (var i = 0; i < units.length; i++) units[i].copyWith(index: i),
      ];

  /// 移动单元 i 与 i+1 之间的边界；两侧首尾镜头联动裁剪（被越过的镜头边界吞并）
  static List<SemanticUnit>? moveUnitBoundary(
      List<SemanticUnit> units, int i, int rawMs,
      {required double fps}) {
    if (i < 0 || i + 1 >= units.length) return null;
    final durationMs = units.last.endMs;
    final left = units[i];
    final right = units[i + 1];
    final minB = _frameAfter(left.startMs, fps);
    final maxB = _maxBoundaryLeavingOneFrame(right.endMs, fps);
    if (minB > maxB) return null;
    final b = _snap(rawMs, fps).clamp(minB, maxB);

    var leftShots = left.shots.where((s) => s.startMs < b).toList();
    if (leftShots.isEmpty) {
      leftShots = [Shot(startMs: left.startMs, endMs: b)];
    } else {
      leftShots[leftShots.length - 1] = leftShots.last.copyWith(endMs: b);
    }

    var rightShots = right.shots.where((s) => s.endMs > b).toList();
    if (rightShots.isEmpty) {
      rightShots = [Shot(startMs: b, endMs: right.endMs)];
    } else {
      rightShots[0] = rightShots.first.copyWith(startMs: b);
    }

    final newLeft = left.copyWith(endMs: b, shots: leftShots);
    final newRight = right.copyWith(startMs: b, shots: rightShots);
    final result = _reindex([
      ...units.sublist(0, i),
      newLeft,
      newRight,
      ...units.sublist(i + 2),
    ]);
    assert(holdsInvariants(result, durationMs, fps));
    return result;
  }

  /// 移动单元 u 内镜头 s 与 s+1 之间的边界（限制在两镜头内部）
  static List<SemanticUnit>? moveShotBoundary(
      List<SemanticUnit> units, int u, int s, int rawMs,
      {required double fps}) {
    if (u < 0 || u >= units.length) return null;
    final durationMs = units.last.endMs;
    final unit = units[u];
    if (s < 0 || s + 1 >= unit.shots.length) return null;
    final left = unit.shots[s];
    final right = unit.shots[s + 1];
    final minB = _frameAfter(left.startMs, fps);
    final maxB = _maxBoundaryLeavingOneFrame(right.endMs, fps);
    if (minB > maxB) return null;
    final b = _snap(rawMs, fps).clamp(minB, maxB);

    final newShots = [
      ...unit.shots.sublist(0, s),
      left.copyWith(endMs: b),
      right.copyWith(startMs: b),
      ...unit.shots.sublist(s + 2),
    ];
    final newUnit = unit.copyWith(shots: newShots);
    final result = _reindex([
      ...units.sublist(0, u),
      newUnit,
      ...units.sublist(u + 1),
    ]);
    assert(holdsInvariants(result, durationMs, fps));
    return result;
  }

  /// 在 rawMs 处把单元 u 拆成两个（镜头随拆分点切开；台词按 sentences 分配）
  static List<SemanticUnit>? splitUnitAt(
      List<SemanticUnit> units, int u, int rawMs,
      {required double fps, required List<AsrSentence> sentences}) {
    if (u < 0 || u >= units.length) return null;
    final durationMs = units.last.endMs;
    final unit = units[u];
    final minB = _frameAfter(unit.startMs, fps);
    final maxB = _maxBoundaryLeavingOneFrame(unit.endMs, fps);
    if (minB > maxB) return null;
    final b = _snap(rawMs, fps);
    if (b < minB || b > maxB) return null;

    var leftShots = unit.shots.where((s) => s.startMs < b).toList();
    if (leftShots.isEmpty) {
      leftShots = [Shot(startMs: unit.startMs, endMs: b)];
    } else {
      leftShots[leftShots.length - 1] = leftShots.last.copyWith(endMs: b);
    }
    var rightShots = unit.shots.where((s) => s.endMs > b).toList();
    if (rightShots.isEmpty) {
      rightShots = [Shot(startMs: b, endMs: unit.endMs)];
    } else {
      rightShots[0] = rightShots.first.copyWith(startMs: b);
    }

    final overlapping = sentences
        .where((s) => s.startMs < unit.endMs && s.endMs > unit.startMs)
        .toList();
    final (leftText, rightText) = TranscriptSplitter.splitAt(overlapping, b);

    final leftUnit =
        unit.copyWith(endMs: b, transcript: leftText, shots: leftShots);
    final rightUnit =
        unit.copyWith(startMs: b, transcript: rightText, shots: rightShots);

    final result = _reindex([
      ...units.sublist(0, u),
      leftUnit,
      rightUnit,
      ...units.sublist(u + 1),
    ]);
    assert(holdsInvariants(result, durationMs, fps));
    return result;
  }

  /// 单元 u 并入前一单元（镜头列表拼接，原单元边界保留为镜头边界；台词拼接；tags 取并集）
  static List<SemanticUnit>? mergeUnitWithPrevious(
      List<SemanticUnit> units, int u) {
    if (u <= 0 || u >= units.length) return null;
    final prev = units[u - 1];
    final curr = units[u];
    final merged = prev.copyWith(
      endMs: curr.endMs,
      transcript: prev.transcript + curr.transcript,
      tags: {...prev.tags, ...curr.tags}.toList(),
      shots: [...prev.shots, ...curr.shots],
    );
    return _reindex([
      ...units.sublist(0, u - 1),
      merged,
      ...units.sublist(u + 1),
    ]);
  }

  /// 在 rawMs 处把单元 u 内包含该点的镜头拆成两个
  static List<SemanticUnit>? splitShotAt(
      List<SemanticUnit> units, int u, int rawMs, {required double fps}) {
    if (u < 0 || u >= units.length) return null;
    final durationMs = units.last.endMs;
    final unit = units[u];
    final b = _snap(rawMs, fps);
    final s = unit.shots.indexWhere((shot) =>
        _frameAfter(shot.startMs, fps) <= b &&
        b <= _maxBoundaryLeavingOneFrame(shot.endMs, fps));
    if (s == -1) return null;

    final shot = unit.shots[s];
    final newShots = [
      ...unit.shots.sublist(0, s),
      shot.copyWith(endMs: b),
      Shot(startMs: b, endMs: shot.endMs, tags: shot.tags),
      ...unit.shots.sublist(s + 1),
    ];
    final newUnit = unit.copyWith(shots: newShots);
    final result = _reindex([
      ...units.sublist(0, u),
      newUnit,
      ...units.sublist(u + 1),
    ]);
    assert(holdsInvariants(result, durationMs, fps));
    return result;
  }

  /// 单元 u 内镜头 s 并入前一镜头（tags 取并集）
  static List<SemanticUnit>? mergeShotWithPrevious(
      List<SemanticUnit> units, int u, int s) {
    if (u < 0 || u >= units.length) return null;
    final unit = units[u];
    if (s <= 0 || s >= unit.shots.length) return null;
    final prevShot = unit.shots[s - 1];
    final currShot = unit.shots[s];
    final merged = Shot(
      startMs: prevShot.startMs,
      endMs: currShot.endMs,
      tags: {...prevShot.tags, ...currShot.tags}.toList(),
    );
    final newShots = [
      ...unit.shots.sublist(0, s - 1),
      merged,
      ...unit.shots.sublist(s + 1),
    ];
    final newUnit = unit.copyWith(shots: newShots);
    return _reindex([
      ...units.sublist(0, u),
      newUnit,
      ...units.sublist(u + 1),
    ]);
  }

  /// 更新单元台词
  static List<SemanticUnit> updateTranscript(
          List<SemanticUnit> units, int u, String text) =>
      [
        for (var i = 0; i < units.length; i++)
          if (i == u) units[i].copyWith(transcript: text) else units[i],
      ];

  /// 校验不变量（供测试与调试断言用）
  ///
  /// 豁免说明（末端边界不要求帧点）：`durationMs`（真实素材片长）是外部
  /// 数据、不是我们能选择的值——30fps 下 4001/4017/12345/59987 这类非帧点
  /// 片长在真实视频里几乎必然出现。若强行把它对齐到最近帧点，时间线就会
  /// 覆盖不到片尾的那几毫秒，直接违反"单元序列无缝覆盖 `[0,durationMs]`"
  /// 这条优先级更高的不变量。因此这里只豁免**末单元的 `endMs`**（以及随之
  /// 恒等的**末单元内末镜头的 `endMs`**）的帧点检查——两者恒等于
  /// `durationMs`，豁免它们不会破坏"无缝覆盖"，因为 [units.last.endMs] ==
  /// `durationMs` 这条检查依然在上面强制执行。除这两处外，一切边界
  /// （首边界 0、单元间边界、所有单元内的镜头间边界、非末单元的 endMs）
  /// 仍必须是合法帧点。
  static bool holdsInvariants(
      List<SemanticUnit> units, int durationMs, double fps) {
    if (units.isEmpty) return durationMs == 0;
    final frame = frameMs(fps);
    bool isFramePoint(int ms) => _snap(ms, fps) == ms;

    if (units.first.startMs != 0) return false;
    if (units.last.endMs != durationMs) return false;

    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      final isLastUnit = i == units.length - 1;
      if (unit.durationMs < frame) return false;
      if (!isFramePoint(unit.startMs)) return false;
      if (!isLastUnit && !isFramePoint(unit.endMs)) return false;
      if (i > 0 && units[i - 1].endMs != unit.startMs) return false;

      if (unit.shots.isEmpty) return false;
      if (unit.shots.first.startMs != unit.startMs) return false;
      if (unit.shots.last.endMs != unit.endMs) return false;
      for (var j = 0; j < unit.shots.length; j++) {
        final shot = unit.shots[j];
        final isLastShotOfLastUnit = isLastUnit && j == unit.shots.length - 1;
        if (shot.durationMs < frame) return false;
        if (!isFramePoint(shot.startMs)) return false;
        if (!isLastShotOfLastUnit && !isFramePoint(shot.endMs)) return false;
        if (j > 0 && unit.shots[j - 1].endMs != shot.startMs) return false;
      }
    }
    return true;
  }
}
