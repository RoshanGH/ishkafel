import '../analysis/boundary_snapper.dart';
import '../analysis/providers.dart';
import '../models/semantic_unit.dart';
import '../models/shot.dart';
import '../time/timecode.dart';
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

  /// 一帧的**标称**毫秒时长（四舍五入）。
  ///
  /// 从 [ms] 起走 [frames] 帧之后落在哪个毫秒。
  ///
  /// **按帧号加减，不是按毫秒加常数。** 帧点在毫秒轴上非等距（30fps 下
  /// 0,33,67,100…，间距在 33/34 交替），拿 `round(1000/fps)` 当步长走，
  /// 走多了就会少走一帧：30 步 × 33ms = 990ms，而 30 帧是 1000ms。
  /// 而且 `round(1000/29.97)` 和 `round(1000/30)` 都是 33，两种帧率分不开
  /// （见 `docs/2026-09-08-成片时间轴重构-TRD.md` 二、2.5）。
  ///
  /// 起点不在帧点上时先吸到最近的帧再走。结果不会小于 0。
  static int msAfterFrames(int ms, double fps, int frames) {
    if (fps <= 0) return ms < 0 ? 0 : ms;
    final target = _frameIndex(ms, fps) + frames;
    final out = _msOfFrame(target < 0 ? 0 : target, fps);
    return out < 0 ? 0 : out;
  }

  /// 一帧在毫秒轴上的**真实最小跨度**：相邻帧点毫秒值之差的最小值。
  ///
  /// 帧点由 [_msOfFrame] 定义（round(idx*1000/fps)），在毫秒轴上非等距：
  /// 30fps 下是 0,33,67,100,133,167…（间距在 33/34 间交替），60fps 下是
  /// …,967,983,1000…（间距在 16/17 间交替）。因此"一帧至少占多少毫秒"必须
  /// 从帧序号域实测，而不是取 `round(1000/fps)`：
  /// - 30fps：round=33，真实最小间距也是 33 → 恰好安全（历史行为得以保持）
  /// - 24fps：round=42，真实最小间距 41
  /// - 60/59.94fps：round=17，真实最小间距 16
  /// 用偏大的标称值当阈值，会把 60fps 素材上**合法的单帧片段判为非法**，
  /// 也会让 clamp 被迫多留一帧。
  ///
  /// 实现：扫描一秒（ceil(fps) 帧）内相邻帧点的间距取最小值。整数帧率下帧点
  /// 序列以一秒为周期，非整数帧率（29.97/59.94）下相邻间距只可能取
  /// floor/ceil(1000/fps) 两个值，一秒内两者必然都已出现，故扫描一秒足够。
  static int minFrameSpanMs(double fps) {
    if (fps <= 0) return 1;
    var minSpan = 1 << 30;
    var prev = _msOfFrame(0, fps);
    for (var k = 1; k <= fps.ceil(); k++) {
      final cur = _msOfFrame(k, fps);
      final span = cur - prev;
      if (span < minSpan) minSpan = span;
      prev = cur;
    }
    // 帧率高到相邻帧点重合时（>1000fps）退化为 1ms，保证阈值恒为正
    return minSpan < 1 ? 1 : minSpan;
  }

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
    final gap = minFrameSpanMs(fps);
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

    // 被越过的**内部切点跟着走**，不吞并：那些是检测（或人切）出来的真实
    // 画面切换，拖一下单元边界就把它们丢掉，等于让邻居的首镜头横跨好几个
    // 真实切换——用户还得手动切回来。
    //
    // 但**旧的单元边界本身不保留**：拖这条边界的最常见动机就是「机器把切点
    // 定错了，挪到对的位置」——旧位置在用户眼里是错的。保留它的话，往回挪
    // 一帧就会在邻居里凭空多出一个一帧宽的碎镜头，越修越碎。代价是大幅度
    // 拖动时旧边界处如果真有画面切换会丢一刀，那时再手动切回来即可——
    // 常见动作（微调）必须顺，罕见动作（大挪）可以补。
    final cuts = <int>{
      for (final shot in left.shots.skip(1)) shot.startMs,
      for (final shot in right.shots.skip(1)) shot.startMs,
    };
    // 新区间的每一段都要**继承原镜头的标签与画面描述**（按中点找到它原来
    // 属于哪个镜头）——不然拖一下边界，两个单元里所有镜头的标签全被清空
    final originals = [...left.shots, ...right.shots];
    Shot inherit(int start, int end) {
      final mid = (start + end) ~/ 2;
      for (final shot in originals) {
        if (mid >= shot.startMs && mid < shot.endMs) {
          return shot.copyWith(startMs: start, endMs: end);
        }
      }
      return Shot(startMs: start, endMs: end);
    }

    List<Shot> partition(int start, int end) {
      final inside = cuts.where((c) => c > start && c < end).toList()..sort();
      final points = [start, ...inside, end];
      return [
        for (var k = 0; k + 1 < points.length; k++)
          inherit(points[k], points[k + 1]),
      ];
    }

    final leftShots = partition(left.startMs, b);
    final rightShots = partition(b, right.endMs);

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

    final (leftText, rightText) = _splitTranscript(unit, b, sentences);

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

  /// 拆分单元时把该单元的台词分给左右两段。
  ///
  /// **单元现有台词是唯一权威**：`unit.transcript` 是用户在检查器里看到、
  /// 并且可能刚刚手工改过的文本，也可能是 LLM 改写过的稿子——它未必等于
  /// ASR 逐句原文。此前这里一律用 [TranscriptSplitter.splitAt] 从
  /// [sentences] 重算，于是：
  /// - `sentences` 为空（早期版本创建的任务没存 ASR 句子）时，两段台词被
  ///   一起清空，用户的台词凭空消失；
  /// - 台词被手工编辑/LLM 改写过时，拆分会把它静默还原成 ASR 原文。
  ///
  /// 现在只在"ASR 逐句拼接恰好等于当前台词"（说明台词就是 ASR 原文、没被
  /// 动过）时才走句子时间戳分配这条更精确的路；否则按拆分点在单元时长中的
  /// 比例切分现有台词。两条路径都满足 `left + right == unit.transcript`，
  /// 因此拆分后再合并回来台词逐字复原，绝不会产出两段空台词。
  static (String left, String right) _splitTranscript(
      SemanticUnit unit, int b, List<AsrSentence> sentences) {
    final overlapping = sentences
        .where((s) => s.startMs < unit.endMs && s.endMs > unit.startMs)
        .toList();
    final asrText = overlapping.map((s) => s.text).join();
    if (overlapping.isNotEmpty && asrText == unit.transcript) {
      return TranscriptSplitter.splitAt(overlapping, b);
    }

    final span = unit.endMs - unit.startMs;
    final ratio = span <= 0 ? 0.0 : (b - unit.startMs) / span;
    return TranscriptSplitter.splitTextByRatio(unit.transcript, ratio);
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

  /// 在 rawMs 处把单元 [u] 内**指定的**镜头 [shotIndex] 拆成两个。
  ///
  /// 语义（评审 Critical 2）：只拆调用方点名的那个镜头。此前这里用
  /// `indexWhere` 找"包含拆分点的"镜头，而上层控制器又把选中的 shotIndex
  /// 丢掉了，于是用户选中 S1、播放头停在 S3 时点「在游标处拆分」会拆掉 S3，
  /// 选中态却仍停在 S1——用户完全不知道刚才改了什么、也无从撤回认知。
  /// 现在拆分点不落在指定镜头内部（未能给两侧各留出至少一帧）时一律返回
  /// null，由上层提示"播放头不在所选范围内"，绝不静默改拆别的镜头。
  static List<SemanticUnit>? splitShotAt(
      List<SemanticUnit> units, int u, int rawMs,
      {required double fps, required int shotIndex}) {
    if (u < 0 || u >= units.length) return null;
    final durationMs = units.last.endMs;
    final unit = units[u];
    if (shotIndex < 0 || shotIndex >= unit.shots.length) return null;

    final shot = unit.shots[shotIndex];
    final minB = _frameAfter(shot.startMs, fps);
    final maxB = _maxBoundaryLeavingOneFrame(shot.endMs, fps);
    if (minB > maxB) return null;
    final b = _snap(rawMs, fps);
    if (b < minB || b > maxB) return null;

    final newShots = [
      ...unit.shots.sublist(0, shotIndex),
      shot.copyWith(endMs: b),
      Shot(startMs: b, endMs: shot.endMs, tags: shot.tags),
      ...unit.shots.sublist(shotIndex + 1),
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

  /// 单元 u 内镜头 s 并入前一镜头。
  ///
  /// 标签与画面描述**用被并入方（前一个镜头）的**，与单元层合并同一条规则
  /// （见 `EditConsequence.mergeTags`）。曾经取并集，结果是「近景」和「远景」
  /// 这类本来互斥的描述混在一起，比只保留一组更没法用。
  ///
  /// 合并出来的镜头标为待重打：画面变长了，原来那组标签未必还成立——但也
  /// 不抹掉，重打是异步的，中间抹空会让用户以为标签丢了。
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
      tags: prevShot.tags,
      description: prevShot.description,
      trace: prevShot.trace,
      tagsStale: true,
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
    // 「不小于一帧」的阈值取相邻帧点的真实最小间距：用偏大的标称帧时长会把
    // 60fps 素材上合法的单帧片段误判为非法（30fps 下两者同为 33，行为不变）
    final frame = minFrameSpanMs(fps);
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

  /// 在末尾**加一个原片上没有的单元**。
  ///
  /// 有原片的任务原本有条硬约束：单元必须无缝覆盖整条原片。加单元打破的正是
  /// 这一条——新单元在原片里不存在，它的画面只能来自挑到的素材，成片因此
  /// 比原片长。这是产品决定：「成片变长，不动原片」。
  ///
  /// 为什么只能加在末尾：插到中间的话，它左右两边的原片时间就不连续了，
  /// 而「取自原片的哪一段」还得靠 [SemanticUnit.startMs]/[endMs] 表达。
  /// 想让它排到前面去，加完再拖——顺序由列表决定（见 `unit_reorder.dart`）。
  ///
  /// 时长先给一个占位（挑到素材后由上层按素材真实时长重排），
  /// 并按 [fps] 吸到整帧——**成片位置是各段时长一路累加出来的**，这里带个
  /// 零头，后面每一段都跟着偏，拼到片尾越差越多。而界面显示的是帧，
  /// 人看到的就是「每一段都对，加起来差了一帧」。fps 给 0 表示读不出帧率，
  /// 那就不动它（读不出帧率不该让时长凭空变一下）。
  static List<SemanticUnit> appendUnit(List<SemanticUnit> units,
      {double fps = 0}) {
    final start = units.isEmpty ? 0 : units.last.endMs;
    return [
      ...units,
      SemanticUnit(
        index: units.length,
        startMs: start,
        endMs: start + alignToFrame(appendedUnitPlaceholderMs, fps),
        // 原片上没有这一段，台词和镜头本来就不存在
        transcript: '',
        shots: const [],
        hasSource: false,
      ),
    ];
  }

  /// 新加的单元在时间线上先占多长。跟空白任务的占位同一个值——
  /// 格子上明确写着「待填」，挑到素材后按真实时长重排
  static const int appendedUnitPlaceholderMs = 10000;
}
