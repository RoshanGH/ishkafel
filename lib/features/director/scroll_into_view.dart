import 'package:flutter/material.dart';

/// 把自己滚到眼前。
///
/// **两半缺一不可，因为 ListView 是懒构建的**：
///
/// - 目标行**已经在树上**（就在视口边上）→ [didUpdateWidget] 这一半管用
/// - 目标行**还没构建**（远在视口之外）→ 它的 State 根本不存在，
///   什么回调都不会来。这一半得由外面先 [ensureIndexVisible] 粗滚过去，
///   把它带进构建范围；等它真被建出来，[initState] 这一半再精确对齐
///
/// 只做前一半的后果，真机上是这样的：右栏一屏放得下三四行卡片，Agent 从
/// 第 1 行做到第 25 行，界面在第 4 行之后就再也不动了。播报条一直在说
/// 「正在给第 11 行找镜头」，画面停在第 1 行——**可视模式退化成一条日志**。
/// 此刻**真的在树上**的那些行。
///
/// 粗滚（[ensureIndexVisible]）的唯一职责是「把还没构建的行带进构建范围」。
/// 已经构建出来的行，位置由行自己精确对齐——这时粗滚再按平均行高估一个
/// 落点滚过去，只会把已经对准的画面拽回去（真机上就是那个「不停从这一行
/// 跳回第一行」）。
class BuiltRows {
  final Set<int> _rows = <int>{};

  void mark(int index) => _rows.add(index);
  void unmark(int index) => _rows.remove(index);
  bool has(int index) => _rows.contains(index);
  void clear() => _rows.clear();
}

class ScrollIntoView extends StatefulWidget {
  final bool active;
  final Widget child;

  /// 这是第几行。给了 [registry] 才有意义
  final int? index;

  /// 登记「我已经在树上了」，让粗滚知道不用为这一行出手
  final BuiltRows? registry;

  /// 停在视口的哪个位置（0 = 顶，1 = 底）
  final double alignment;

  const ScrollIntoView({
    super.key,
    required this.active,
    required this.child,
    this.index,
    this.registry,
    this.alignment = 0.25,
  });

  @override
  State<ScrollIntoView> createState() => _ScrollIntoViewState();
}

class _ScrollIntoViewState extends State<ScrollIntoView> {
  @override
  void initState() {
    super.initState();
    if (widget.index != null) widget.registry?.mark(widget.index!);
    // 刚被建出来就已经是焦点：多半是外面粗滚把它带进了构建范围，
    // 这一下负责精确对齐
    if (widget.active) _reveal();
  }

  @override
  void dispose() {
    if (widget.index != null) widget.registry?.unmark(widget.index!);
    super.dispose();
  }

  @override
  void didUpdateWidget(ScrollIntoView old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      if (old.index != null) old.registry?.unmark(old.index!);
      if (widget.index != null) widget.registry?.mark(widget.index!);
    }
    if (widget.active && !old.active) _reveal();
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      Scrollable.ensureVisible(context,
          alignment: widget.alignment,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 第 [index] 行大概在什么偏移上（共 [count] 行，可滚动范围 [maxExtent]）。
///
/// 按等分估——行高其实不等（有的行挂着好几个镜头），所以这只是个**粗略
/// 落点**：把目标行带进构建范围就算成功，剩下的对齐交给 [ScrollIntoView]。
/// 想精确就得记住每一行的实际高度，为这点收益不值当。
double estimateOffsetFor({
  required int index,
  required int count,
  required double maxExtent,
}) {
  if (count <= 1 || maxExtent <= 0) return 0;
  final ratio = index / (count - 1);
  return (maxExtent * ratio).clamp(0, maxExtent);
}

/// 把第 [index] 行粗滚到视口里。**它已经在眼前的话什么都不做**——
/// 那种情况下再滚一次只会让画面无谓地跳一下。
void ensureIndexVisible({
  required ScrollController controller,
  required int index,
  required int count,

  /// 这一行**已经在树上**了吗。是的话粗滚不出手：它的位置由行自己
  /// 精确对齐，按平均行高估一个落点滚过去只会把对准的画面拽回去
  bool alreadyBuilt = false,
}) {
  if (alreadyBuilt) return;
  if (!controller.hasClients) return;
  final position = controller.position;
  final target = estimateOffsetFor(
      index: index, count: count, maxExtent: position.maxScrollExtent);
  // 估出来的落点已经在当前视口里，说明那一行多半已经构建过了，
  // 交给 ScrollIntoView 去精调就行
  final viewport = position.viewportDimension;
  if (target >= position.pixels && target <= position.pixels + viewport) {
    return;
  }
  controller.animateTo(target,
      duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
}
