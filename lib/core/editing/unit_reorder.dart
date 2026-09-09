import '../audio/bgm_plan.dart';
import '../models/semantic_unit.dart';

/// 调整台词语义单元的**成片顺序**：把 U2 拖到 U1 的位置，它就成了 U1。
///
/// 为什么这件事成立：成片时间轴本来就是**按列表顺序**走游标算出来的
/// （见 [ComposedTimeline]），不是按 `startMs` 排的。所以换了列表顺序，
/// 成片里的先后就跟着变了，单元的 `startMs`/`endMs` 退化成「我取自原片的
/// 哪一段」——它跟着单元一起搬，不重算。
///
/// **挂在单元上的东西一份都不用搬**：替换方案、配音、手改字幕、生成好的
/// 配音文件都按单元自己的身份记（[SemanticUnit.uid]），单元怎么排都还是它。
///
/// 这里曾经放着四个 remap 函数，一份一份地把按位置记的数据挪到新位置——
/// 半年里漏搬过三次，每次都是「不报错，只有把片子导出来看一遍才发现」。
/// 现在只剩配乐：它记的是**区间**（哪几段连着铺一首曲子），挪动会改变
/// 「这一段盖住谁」，那是要跟人说清楚的事，不是搬一下就完的。

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
