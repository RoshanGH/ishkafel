import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../analysis/providers.dart';
import '../models/semantic_unit.dart';
import '../models/unit_uid.dart';
import 'edit_locks.dart';
import 'segmentation_edit_ops.dart';

/// 审片台当前选中对象：选中单元或选中单元内某个镜头
class EditorSelection {
  final int unitIndex;
  final int? shotIndex; // shotIndex==null 表示选中单元

  const EditorSelection.unit(this.unitIndex) : shotIndex = null;
  const EditorSelection.shot(this.unitIndex, int this.shotIndex);
}

/// 编辑器状态机：持有当前 units、选中、undo/redo 栈；操作全部转发 [SegmentationEditOps] 纯函数
///
/// 约定：
/// - 操作成功（纯函数返回非 null）→ 推入 undo 栈（存操作前的 units 快照）、
///   清空 redo 栈、notifyListeners、返回 true
/// - 纯函数返回 null（非法操作）→ 不入栈、不 notify、返回 false
/// - [dirty] 用深度相等（[SemanticUnit] 已实现 ==）判断当前 units 是否偏离 initialUnits
/// - 编辑会话（[beginDragSession]/[endDragSession]、[beginTextSession]/
///   [endTextSession]）：两者都遵循"开始时记快照、结束时按差异合并为单条
///   记录"的机制——拖拽一次边界手柄会触发几十次 moveUnitBoundary/
///   moveShotBoundary 调用，台词框聚焦期间的连续键入同理会触发几十次
///   updateTranscript 调用；若每次都单独入栈，用户要撤销几十次才能回退
///   一次拖动/一次编辑。会话期间操作直接替换 _units、notify，但不入栈；
///   会话结束时若相对会话开始快照确有变化，才把快照作为**单条** undo
///   记录压栈。
///   拖拽会话与文本会话各自持有独立的快照字段（[_dragSessionSnapshot]/
///   [_textSessionSnapshot]），互不干扰：曾经共用同一个字段，导致
///   `TimelineView` 在任意水平拖拽结束时（包括未命中边界手柄、纯滚动的
///   拖拽）都会无条件调用 `endDragSession()`，若此时台词编辑会话正在进行
///   中，会被错误地提前提交/终止（把两次互不相关的编辑压成一条 undo 记
///   录，甚至让"文本会话仍在进行"这一状态被意外清除）。拆成两个独立字段
///   后，`endDragSession()`/`endTextSession()` 只消费各自的会话，互不影响。
class SegmentationEditorController extends ChangeNotifier {
  /// 时间轴总长。
  ///
  /// 有原片的任务是原片时长，一经建立不变。**空白任务是分子加出来的**——加一个
  /// 分子、挑到一条更长的素材，总长就变了，所以这里不能是 final
  int durationMs;
  final double fps;
  final List<AsrSentence> sentences;

  final List<SemanticUnit> _initialUnits;
  List<SemanticUnit> _units;
  EditorSelection? _selection;

  final List<List<SemanticUnit>> _undoStack = [];
  final List<List<SemanticUnit>> _redoStack = [];

  /// 拖拽会话开始时的 units 快照；非 null 表示当前处于拖拽会话中。
  /// 与 [_textSessionSnapshot] 相互独立，见类文档「编辑会话」。
  List<SemanticUnit>? _dragSessionSnapshot;

  /// 文本（台词）编辑会话开始时的 units 快照；非 null 表示当前处于文本
  /// 会话中。与 [_dragSessionSnapshot] 相互独立，见类文档「编辑会话」。
  List<SemanticUnit>? _textSessionSnapshot;

  static const _unitsEq = ListEquality<SemanticUnit>();

  SegmentationEditorController({
    required List<SemanticUnit> initialUnits,
    required this.durationMs,
    required this.fps,
    required this.sentences,
  })  : _initialUnits = ensureUnitUids(initialUnits),
        _units = ensureUnitUids(initialUnits),
        _unitsView = List.unmodifiable(ensureUnitUids(initialUnits));

  /// 当前切分结构（**只读视图**）。
  ///
  /// 直接把内部列表交出去时，外部一次 `units.removeAt(0)` 就能绕过 undo 栈
  /// 与不变量校验把切分结构改坏，而且没有任何提示。视图做缓存而不是每次
  /// `List.unmodifiable`：这个 getter 在绘制与列表构建路径上被高频调用，
  /// 每次分配一个包装对象是无谓开销。
  List<SemanticUnit> get units => _unitsView;

  List<SemanticUnit> _unitsView = const [];
  EditorSelection? get selection => _selection;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  bool get dirty => !_unitsEq.equals(_units, _initialUnits);

  /// 当前是否处于拖拽会话中（与文本编辑会话相互独立，见类文档）
  bool get inDragSession => _dragSessionSnapshot != null;

  /// 当前是否处于台词编辑会话中（与拖拽会话相互独立，见类文档）
  bool get inTextSession => _textSessionSnapshot != null;

  /// 挑过替换素材的单元/镜头，切分钉死（见 [EditLocks]）。
  /// 由上层在替换方案变化时推进来
  EditLocks get locks => _locks;
  EditLocks _locks = EditLocks.none;

  set locks(EditLocks next) {
    if (next == _locks) return;
    _locks = next;
    notifyListeners();
  }

  /// 上一次结构操作是被锁挡下来的吗；是的话这里是**能直接展示给用户**的原因。
  ///
  /// 单独开一个字段而不是把返回值改成结果对象：这些操作有几十个调用点和
  /// 测试，为了一个提示语把签名全改一遍不划算。读完请调用方自己清掉。
  String? get blockedReason => _blockedReason;
  String? _blockedReason;

  /// 上一次拦截是不是「已选替换素材」的锁——UI 据此决定要不要附
  /// 「去看素材」的入口（播放头出界这类拦截给这个入口只会把人带偏）
  bool get blockedByMaterialLock => _blockedByMaterialLock;
  bool _blockedByMaterialLock = false;

  /// 取走并清空上一次的拦截原因——UI 弹完提示就该忘掉它
  String? takeBlockedReason() {
    final reason = _blockedReason;
    _blockedReason = null;
    return reason;
  }

  bool _block(String reason, {bool materialLock = true}) {
    _blockedReason = reason;
    _blockedByMaterialLock = materialLock;
    notifyListeners();
    return false;
  }

  /// 设置选中对象；若 [s] 越界（unitIndex/shotIndex 超出当前 units 结构）
  /// 则置为 null，而不是保留一个悬空的选中态（调用方可能传入过期下标，
  /// 例如异步回调延迟到达时结构已变化）。
  void select(EditorSelection? s) {
    _selection = _clampSelection(s);
    notifyListeners();
  }

  /// 把选中对象移动到相邻的一个（[delta] 为 +1 向后、-1 向前）。
  ///
  /// 未选中时选第一个；到头/到尾停住不回绕（回绕会让用户失去位置感）。
  /// 镜头层跨单元连续移动：视觉镜头是连续覆盖整片的，导航到单元末尾就卡住
  /// 不符合直觉。
  void selectAdjacent(int delta) {
    if (_units.isEmpty || delta == 0) return;
    final sel = _selection;
    if (sel == null) {
      select(EditorSelection.unit(delta > 0 ? 0 : _units.length - 1));
      return;
    }
    if (sel.shotIndex == null) {
      final next = (sel.unitIndex + delta).clamp(0, _units.length - 1);
      select(EditorSelection.unit(next));
      return;
    }
    select(_adjacentShot(sel.unitIndex, sel.shotIndex!, delta));
  }

  /// 镜头层的相邻位置（跨单元）
  EditorSelection _adjacentShot(int u, int s, int delta) {
    var unit = u;
    var shot = s + delta;
    while (shot < 0) {
      if (unit == 0) return EditorSelection.shot(0, 0);
      unit--;
      shot += _units[unit].shots.length;
    }
    while (shot >= _units[unit].shots.length) {
      if (unit == _units.length - 1) {
        return EditorSelection.shot(unit, _units[unit].shots.length - 1);
      }
      shot -= _units[unit].shots.length;
      unit++;
    }
    return EditorSelection.shot(unit, shot);
  }

  /// 当前选中对象的起点（毫秒）；未选中返回 null。
  /// 供上层在键盘导航后把播放头同步过去。
  int? get selectedStartMs {
    final sel = _selection;
    if (sel == null) return null;
    final unit = _units[sel.unitIndex];
    final s = sel.shotIndex;
    return s == null ? unit.startMs : unit.shots[s].startMs;
  }

  /// 开启拖拽会话：记录当前 units 作为会话快照；重复调用无副作用（幂等，
  /// `??=` 保证嵌套 begin 不会覆盖已有快照）。与文本会话互不干扰。
  void beginDragSession() {
    _dragSessionSnapshot ??= _units;
  }

  /// 结束拖拽会话：若相对会话开始时的快照确有变化，把快照作为单条 undo 记录
  /// 压栈（并清空 redo 栈）；无变化则什么都不做。不在拖拽会话中时调用无副
  /// 作用——即便此时文本会话正在进行中，也不会消费/结束文本会话。
  void endDragSession() {
    final snapshot = _dragSessionSnapshot;
    if (snapshot == null) return;
    _dragSessionSnapshot = null;
    if (!_unitsEq.equals(_units, snapshot)) {
      _undoStack.add(snapshot);
      _redoStack.clear();
    }
  }

  /// 开启台词编辑会话：语义与 [beginDragSession] 完全一致（见类文档「编辑
  /// 会话」），供 InspectorPanel 在台词 TextField 获得焦点时调用，使聚焦
  /// 期间连续多次 [updateTranscript]（逐击键入）合并为一条 undo 记录。
  void beginTextSession() {
    _textSessionSnapshot ??= _units;
  }

  /// 结束台词编辑会话：供 InspectorPanel 在台词 TextField 失去焦点时调用。
  /// 不在文本会话中时调用无副作用——即便此时拖拽会话正在进行中，也不会
  /// 消费/结束拖拽会话。
  void endTextSession() {
    final snapshot = _textSessionSnapshot;
    if (snapshot == null) return;
    _textSessionSnapshot = null;
    if (!_unitsEq.equals(_units, snapshot)) {
      _undoStack.add(snapshot);
      _redoStack.clear();
    }
  }

  /// 校验 selection 是否仍落在当前 _units 结构内；越界则置为 null（安全兜底）
  EditorSelection? _clampSelection(EditorSelection? sel) {
    if (sel == null) return null;
    final u = sel.unitIndex;
    if (u < 0 || u >= _units.length) return null;
    final s = sel.shotIndex;
    if (s == null) return sel;
    final shots = _units[u].shots;
    if (s < 0 || s >= shots.length) return null;
    return sel;
  }

  /// 将纯函数结果应用到当前状态：成功则入栈、清 redo、（按需重映射 selection 或做
  /// 越界兜底）、notify；失败返回 false。
  ///
  /// [remapSelection] 用于结构会改变（如合并导致单元/镜头数量减少）而需要显式指定
  /// 新 selection 的场景；仅在操作成功时才会被调用。不传时默认对现有 selection 做
  /// 越界兜底（结构不变的操作如移动边界、拆分前半部分天然保持有效，因此这里的兜底
  /// 只是防御，不会误伤合法 selection）。
  /// 整批换掉分子列表（**只给空白任务用**）。
  ///
  /// 有原片的任务的编辑一律走 [SegmentationEditOps] 那套带不变量校验的操作：
  /// 那边有一条固定的原片时长要无缝覆盖。空白任务没有原片，分子是加出来的，
  /// 总长跟着变——这条通路把两者分开，免得为了让「加一个分子」通过校验而把
  /// 那套不变量放松掉。
  void replaceUnitsForBlankTask(List<SemanticUnit> rawUnits, int totalMs) {
    final units = ensureUnitUids(rawUnits);
    _undoStack.add(_units);
    _redoStack.clear();
    _units = units;
    _unitsView = List.unmodifiable(units);
    durationMs = totalMs;
    _selection = _clampSelection(_selection);
    notifyListeners();
  }

  bool _apply(List<SemanticUnit>? raw,
      {EditorSelection? Function()? remapSelection}) {
    if (raw == null) return false;
    // **单元进编辑器的唯一闸口**：拆分/合并/手动添加造出来的新单元还是空
    // 身份，在这里补发。跑过之后就有一条保证——编辑器里的单元一定有身份、
    // 而且互不相同，挂在它下面的东西可以放心拿它当键（见 [ensureUnitUids]）
    final result = ensureUnitUids(raw);
    // 会话中（拖拽或台词编辑）：不逐次入栈，交由 endDragSession/
    // endTextSession 合并为一条记录
    if (_dragSessionSnapshot == null && _textSessionSnapshot == null) {
      _undoStack.add(_units);
      _redoStack.clear();
    }
    _units = result;
    _unitsView = List.unmodifiable(result);
    _selection =
        remapSelection != null ? remapSelection() : _clampSelection(_selection);
    notifyListeners();
    return true;
  }

  /// 移动第 [i] 与第 [i+1] 个单元之间的边界。两侧任一个挑过素材就不许动：
  /// 边界一变，那一段的时长就变了，已经按旧时长变速好的素材全对不上
  bool moveUnitBoundary(int i, int rawMs) {
    final blocked = _unitBoundaryBlock(i);
    if (blocked != null) return _block(blocked);
    return _apply(SegmentationEditOps.moveUnitBoundary(_units, i, rawMs, fps: fps));
  }

  /// 移动单元 [u] 内第 [s] 与第 [s+1] 个镜头之间的边界
  bool moveShotBoundary(int u, int s, int rawMs) {
    // **镜头这一层的锁**：固定过底片的单元放行——那些镜头是这条素材上的
    // 刀口，调它们正是这个功能要给的能力（见 [EditLocks.isShotBoundaryLocked]）
    if (_locks.isShotBoundaryLocked(u)) return _block(LockWording.unit(u));
    for (final shot in [s, s + 1]) {
      if (_locks.isShotLocked(u, shot)) {
        return _block(LockWording.shot(u, shot));
      }
    }
    return _apply(
        SegmentationEditOps.moveShotBoundary(_units, u, s, rawMs, fps: fps));
  }

  /// 单元边界两侧有没有钉死的东西。移动它会改到两侧单元的首/尾镜头，
  /// 所以整段被换掉、或者贴着边界的那个镜头挑过素材，都不能动
  String? _unitBoundaryBlock(int i) {
    for (final u in [i, i + 1]) {
      if (u < 0 || u >= _units.length) continue;
      if (_locks.isUnitLocked(u)) return LockWording.unit(u);
      // 两侧单元里**任何**挑过素材的镜头都要锁，不只是贴着边界的那颗：
      // 边界一动，镜头会在两个单元之间转移，两侧的镜头下标都可能变——
      // 而替换方案是按下标记的，下标一移素材就串位。原来只查贴边那颗，
      // U3 的 S3 挑过素材、拖边界吞掉 S1 之后 S3 变 S2，素材就跑错了镜头
      final locked = _locks.lockedShotsIn(u);
      if (locked.isNotEmpty) {
        return LockWording.shotsInUnit(u, locked);
      }
    }
    return null;
  }

  /// 在播放头处拆分——**播放头在哪一帧就切哪一帧**。
  ///
  /// 层级跟当前选中走：选中的是视觉镜头就切镜头层，其余（选中单元或
  /// 什么都没选）切台词语义单元层；**对象自动取播放头所在的那一个**。
  /// 曾经要求「先选中、且播放头必须落在选中对象范围内」——那是让用户
  /// 去满足一个看不见的前置条件，真机上把同事困住过。
  bool splitSelectedAt(int rawMs) {
    final unitIndex =
        _units.indexWhere((u) => rawMs >= u.startMs && rawMs < u.endMs);
    if (unitIndex < 0) {
      return _block('播放头不在片子范围内，没有可拆分的位置——把它移到要拆的地方再按拆分',
          materialLock: false);
    }
    final wantShotLayer = _selection?.shotIndex != null;

    if (!wantShotLayer) {
      // 单元一拆两半，里面的镜头下标全变——只要单元里有任何挑过素材的东西
      // 都不能拆，否则钉在 S6 上的素材会跑到别的镜头上
      final blocked = _unitStructureBlock(unitIndex);
      if (blocked != null) return _block(blocked);
      final result = SegmentationEditOps.splitUnitAt(_units, unitIndex, rawMs,
          fps: fps, sentences: sentences);
      if (result == null) {
        return _block(
            '播放头贴着 U${unitIndex + 1} 的现有边界，拆不出新的一段——往中间挪几帧再拆',
            materialLock: false);
      }
      return _apply(result);
    }

    final shots = _units[unitIndex].shots;
    final shotIndex =
        shots.indexWhere((sh) => rawMs >= sh.startMs && rawMs < sh.endMs);
    if (shotIndex < 0) {
      return _block(
          '播放头这个位置在 U${unitIndex + 1} 里、但不在任何视觉镜头上——往旁边挪几帧再拆',
          materialLock: false);
    }
    if (_locks.isShotBoundaryLocked(unitIndex)) {
      return _block(LockWording.unit(unitIndex));
    }
    if (_locks.isShotLocked(unitIndex, shotIndex)) {
      return _block(LockWording.shot(unitIndex, shotIndex));
    }
    final result = SegmentationEditOps.splitShotAt(_units, unitIndex, rawMs,
        fps: fps, shotIndex: shotIndex);
    if (result == null) {
      return _block(
          '播放头贴着 U${unitIndex + 1}·S${shotIndex + 1} 的现有边界，拆不出新的一段——往中间挪几帧再拆',
          materialLock: false);
    }
    return _apply(result);
  }

  /// 整个单元的结构要动（拆分/合并）时的拦截原因
  String? _unitStructureBlock(int u) {
    if (_locks.isUnitLocked(u)) return LockWording.unit(u);
    final lockedShots = _locks.lockedShotsIn(u);
    if (lockedShots.isNotEmpty) return LockWording.shotsInUnit(u, lockedShots);
    return null;
  }

  /// 按选中层分派：选中单元→mergeUnitWithPrevious；选中镜头→mergeShotWithPrevious
  ///
  /// 合并会让目标少一个单元/镜头，因此成功后需显式把 selection 重映射到合并后的
  /// 对象（单元层→unit(u-1)；镜头层→shot(u, s-1)），而不是留着指向被吞并前的下标。
  bool mergeSelectedWithPrevious() {
    final sel = _selection;
    if (sel == null) return false;
    if (sel.shotIndex == null) {
      final u = sel.unitIndex;
      // 两个单元并成一个，两边的镜头下标都会变，所以两边都要查
      for (final target in [u - 1, u]) {
        final blocked =
            target < 0 ? null : _unitStructureBlock(target);
        if (blocked != null) return _block(blocked);
      }
      return _apply(SegmentationEditOps.mergeUnitWithPrevious(_units, u),
          remapSelection: () => EditorSelection.unit(u - 1));
    }
    final u = sel.unitIndex;
    final s = sel.shotIndex!;
    if (_locks.isShotBoundaryLocked(u)) return _block(LockWording.unit(u));
    // 被吞的和吞人的都动了：一个消失、一个变长
    for (final shot in [s - 1, s]) {
      if (shot >= 0 && _locks.isShotLocked(u, shot)) {
        return _block(LockWording.shot(u, shot));
      }
    }
    return _apply(SegmentationEditOps.mergeShotWithPrevious(_units, u, s),
        remapSelection: () => EditorSelection.shot(u, s - 1));
  }

  /// ±N 帧步进调整选中对象的边缘：
  /// - 选中单元：startEdge=true 调整与前一单元的边界（moveUnitBoundary(unitIndex-1, ...)，
  ///   首单元返回 false）；startEdge=false 调整与后一单元的边界
  ///   （moveUnitBoundary(unitIndex, ...)，末单元返回 false）
  /// - 选中镜头：同理在单元内换算为 moveShotBoundary
  /// 目标 ms = 当前边界往后走 frames 帧（可为负，表示反方向）。
  /// **按帧号走**，不是按毫秒加常数——见 [SegmentationEditOps.msAfterFrames]
  bool nudgeSelectedEdge({required bool startEdge, required int frames}) {
    final sel = _clampSelection(_selection);
    if (sel == null) return false;

    if (sel.shotIndex == null) {
      final u = sel.unitIndex;
      // 双保险：即便 selection 因某种原因未被及时清理，这里也不会越界解引用
      if (u < 0 || u >= _units.length) return false;
      if (startEdge) {
        if (u <= 0) return false;
        final target =
            SegmentationEditOps.msAfterFrames(_units[u].startMs, fps, frames);
        return moveUnitBoundary(u - 1, target);
      } else {
        if (u >= _units.length - 1) return false;
        final target =
            SegmentationEditOps.msAfterFrames(_units[u].endMs, fps, frames);
        return moveUnitBoundary(u, target);
      }
    }

    final u = sel.unitIndex;
    if (u < 0 || u >= _units.length) return false;
    final s = sel.shotIndex!;
    final shots = _units[u].shots;
    if (s < 0 || s >= shots.length) return false;
    if (startEdge) {
      if (s <= 0) return false;
      final target =
          SegmentationEditOps.msAfterFrames(shots[s].startMs, fps, frames);
      return moveShotBoundary(u, s - 1, target);
    } else {
      if (s >= shots.length - 1) return false;
      final target =
          SegmentationEditOps.msAfterFrames(shots[s].endMs, fps, frames);
      return moveShotBoundary(u, s, target);
    }
  }

  bool updateTranscript(int u, String text) {
    if (u < 0 || u >= _units.length) return false;
    return _apply(SegmentationEditOps.updateTranscript(_units, u, text));
  }

  /// 整体换掉 units，用于「不改切分、只改附属信息」的场景（打标结果回填、
  /// 标记标签过期）。走 [_apply] 因此照常入 undo 栈——⌘Z 能把它撤回去。
  ///
  /// 长度必须一致：这个入口不负责改结构，长度变了说明调用方拿错了数据，
  /// 让它悄悄生效会把 selection 和替换方案一起搞错位。
  bool replaceUnits(List<SemanticUnit> next) {
    if (next.length != _units.length) return false;
    return _apply(next);
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    final previous = _undoStack.removeLast();
    _redoStack.add(_units);
    _units = previous;
    _unitsView = List.unmodifiable(previous);
    // 撤销可能让 units 数量发生变化（如撤销一次拆分会变少），
    // 需要重新校验 selection 是否仍落在有效范围内
    _selection = _clampSelection(_selection);
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    final next = _redoStack.removeLast();
    _undoStack.add(_units);
    _units = next;
    _unitsView = List.unmodifiable(next);
    _selection = _clampSelection(_selection);
    notifyListeners();
  }
}
