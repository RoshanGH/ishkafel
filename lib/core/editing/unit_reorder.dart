import '../audio/bgm_plan.dart';
import '../audio/voice_plan.dart';
import '../models/semantic_unit.dart';
import '../replacement/replacement_plan.dart';

/// 调整台词语义单元的**成片顺序**：把 U2 拖到 U1 的位置，它就成了 U1。
///
/// 为什么这件事成立：成片时间轴本来就是**按列表顺序**走游标算出来的
/// （见 [ComposedTimeline]），不是按 `startMs` 排的。所以换了列表顺序，
/// 成片里的先后就跟着变了，单元的 `startMs`/`endMs` 退化成「我取自原片的
/// 哪一段」——它跟着单元一起搬，不重算。
///
/// **真正的风险不在列表本身，在旁边那三份按下标记的数据**：替换方案、配音、
/// 配乐。它们不跟着搬不会报错，只会让成片悄悄变成另一个样子——挑给 U2 的
/// 素材跑到 U1 身上、配音念错段落、配乐盖错地方。这个文件把它们放在一起，
/// **加第四种按下标记的东西时不会漏**（同 [shiftReplacementsAfterRemoval]
/// 那一组的用意）。

/// 挪单元。越界或原地不动都原样返回入参本身（调用方可以 `identical` 判断）
List<SemanticUnit> moveUnit(
  List<SemanticUnit> units, {
  required int from,
  required int to,
}) {
  if (!_movable(units.length, from, to)) return units;
  final next = moveIndexed(units, from: from, to: to);
  return [
    // 下标必须跟位置一致：所有按下标记的东西都指着它
    for (var i = 0; i < next.length; i++) next[i].copyWith(index: i),
  ];
}

/// 替换方案按列表下标记，跟着同样挪一次。
///
/// [unitCount] 是**单元数**，不是方案数——这两个可以不一样：加一个单元时
/// 方案列表不会跟着长出一条，于是出现「单元 6 个、方案 5 条」。
/// 拿方案数去判断 from/to 合不合法的话，把第 6 个单元拖到最前面会因为
/// `from=5` 超出方案列表长度而**整个跳过重排**，素材就全跟错了单元。
///
/// 2026-09-07 真机上就是这么把素材 114799 从 U3 挪到了别人身上——不报错，
/// 只有把片子导出来看一遍才可能发现。所以这里先按单元数补齐再挪。
List<UnitReplacement> remapReplacementsAfterMove(
  List<UnitReplacement> replacements, {
  required int from,
  required int to,
  required int unitCount,
}) {
  if (!_movable(unitCount, from, to)) return replacements;
  // 补齐到单元数：缺的那些是「还没挑素材」，等同于保留原片
  final padded = [
    ...replacements,
    for (var i = replacements.length; i < unitCount; i++)
      UnitReplacement.keepOriginal(),
  ];
  return List.unmodifiable(moveIndexed(padded, from: from, to: to));
}

/// 配音按 [VoiceAssignment.unitIndex] 记，每条各自换算到新位置
VoicePlan remapVoicesAfterMove(
  VoicePlan plan, {
  required int from,
  required int to,
}) {
  if (from == to) return plan;
  return VoicePlan([
    for (final a in plan.assignments)
      VoiceAssignment(
          unitIndex: _mapIndex(a.unitIndex, from: from, to: to),
          voice: a.voice),
  ]);
}

/// 配乐挪动的结果：新方案 + **被打断的那几段**。
///
/// 分开返回是因为配乐记的是**区间**（[BgmSegment.startUnit]~[endUnit]），
/// 把区间里的单元挪到区间外，这段配乐盖的范围就变了。悄悄改成另一个样子
/// 是不行的——用户当初是照着某几段的内容选的曲子。调用方拿到
/// [brokenSegments] 要把它说出来。
class BgmMoveResult {
  final BgmPlan plan;

  /// 覆盖范围被改动的段落（新方案里的下标）
  final List<int> brokenSegments;

  const BgmMoveResult(this.plan, this.brokenSegments);
}

BgmMoveResult remapBgmAfterMove(
  BgmPlan plan, {
  required int from,
  required int to,
}) {
  if (from == to) return BgmMoveResult(plan, const []);
  final kept = <BgmSegment>[];
  final broken = <int>[];
  for (final segment in plan.segments) {
    // 按**成员**算，不是按端点算：端点各自映射再取 min/max，遇到「区间里的
    // 单元被挪到区间外」会把中间那些没被盖过的单元一起圈进来
    final moved = {
      for (var i = segment.startUnit; i <= segment.endUnit; i++)
        _mapIndex(i, from: from, to: to),
    };
    if (_contiguous(moved)) {
      // 这一段盖的还是原来那几个单元，只是下标变了
      kept.add(segment.copyWith(
          startUnit: moved.reduce(_min), endUnit: moved.reduce(_max)));
      continue;
    }
    // 被挪走的那个跑到区间外面去了：它不再属于这一段
    final rest = moved.where((i) => i != to).toSet();
    if (rest.isEmpty) {
      broken.add(-1); // 整段没了，也要点名
      continue;
    }
    kept.add(segment.copyWith(
        startUnit: rest.reduce(_min), endUnit: rest.reduce(_max)));
    broken.add(kept.length - 1);
  }
  return BgmMoveResult(BgmPlan(kept), List.unmodifiable(broken));
}

int _min(int a, int b) => a < b ? a : b;
int _max(int a, int b) => a > b ? a : b;

/// 这几个下标是不是连成一片（配乐只能盖连续的一段）
bool _contiguous(Set<int> indexes) =>
    indexes.reduce(_max) - indexes.reduce(_min) + 1 == indexes.length;

bool _movable(int length, int from, int to) =>
    from != to && from >= 0 && from < length && to >= 0 && to < length;

/// 一个旧下标在挪动之后落到哪里
/// **挪一格：先取出来，再插到最终下标上。全项目只有这一处定义这件事。**
///
/// 曾经是「先 insert 再 remove」，往后挪时落点少一格——挪到相邻的下一位
/// （`to == from + 1`）**完全是个空操作**：人拖了一下，列表纹丝不动。
/// 而配音、配乐走的是 [_mapIndex]，语义是对的。同一件事两套算法，
/// 结果自然对不上：单元挪了、挑给它的素材没跟着走（2026-09-08 真机）。
///
/// 现在这一处和 [_mapIndex] 必须永远一致，有穷举测试盯着
/// （`test/core/editing/reorder_index_agreement_test.dart`）。
List<T> moveIndexed<T>(List<T> list, {required int from, required int to}) {
  final out = [...list];
  out.insert(to, out.removeAt(from));
  return out;
}

/// 挪完之后，原来第 [index] 个去了哪儿。和 [moveIndexed] 是同一套语义
int _mapIndex(int index, {required int from, required int to}) {
  if (index == from) return to;
  if (from < to) {
    // 往后挪：夹在中间的整体前移一格
    return (index > from && index <= to) ? index - 1 : index;
  }
  // 往前挪：夹在中间的整体后移一格
  return (index >= to && index < from) ? index + 1 : index;
}

/// 从列表里去掉第 [index] 个单元，**只重排下标，一个单元的起止都不动**。
///
/// 空白任务那套（`BlankUnitOps.removeAt`）会把所有单元的 `startMs/endMs`
/// 重新铺成连续的一条。对空白任务那是对的——它的时间轴就是分子一个个排出来
/// 的，而且分子里根本没有视觉镜头。
///
/// **有原片的任务不行**：那里单元的起止是原片坐标，单元里的视觉镜头也是
/// 原片坐标。把单元挪了、镜头不动，两层就此对不上——镜头轨画到别处、单元
/// 尾部空出一截、点中的和播的不是同一段。2026-09-09 真机上「合并视觉镜头
/// 之后后面变成缺失的」「选中镜头后预览跳回 U1·S1」都是这么来的：起因不是
/// 合并，是在那之前删过一个手动加的台词语义单元。
List<SemanticUnit> removeUnitAt(List<SemanticUnit> units, int index) {
  if (index < 0 || index >= units.length) return units;
  final next = [...units]..removeAt(index);
  return [
    for (var i = 0; i < next.length; i++) next[i].copyWith(index: i),
  ];
}

/// 这批单元覆盖到原片的第几毫秒——**取最大值，不是取最后一个**。
///
/// 列表顺序就是成片顺序，和原片顺序无关：手加的单元拖到最前、或者单元被
/// 调过序之后，`units.last.endMs` 就不再是覆盖的终点了。
int coveredEndMs(List<SemanticUnit> units) {
  var end = 0;
  for (final u in units) {
    if (u.endMs > end) end = u.endMs;
  }
  return end;
}
