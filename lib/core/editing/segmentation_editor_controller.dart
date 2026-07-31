import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../analysis/providers.dart';
import '../models/semantic_unit.dart';
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
  final int durationMs;
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
  })  : _initialUnits = initialUnits,
        _units = initialUnits;

  List<SemanticUnit> get units => _units;
  EditorSelection? get selection => _selection;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  bool get dirty => !_unitsEq.equals(_units, _initialUnits);

  /// 当前是否处于拖拽会话中（与文本编辑会话相互独立，见类文档）
  bool get inDragSession => _dragSessionSnapshot != null;

  /// 当前是否处于台词编辑会话中（与拖拽会话相互独立，见类文档）
  bool get inTextSession => _textSessionSnapshot != null;

  /// 设置选中对象；若 [s] 越界（unitIndex/shotIndex 超出当前 units 结构）
  /// 则置为 null，而不是保留一个悬空的选中态（调用方可能传入过期下标，
  /// 例如异步回调延迟到达时结构已变化）。
  void select(EditorSelection? s) {
    _selection = _clampSelection(s);
    notifyListeners();
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
  bool _apply(List<SemanticUnit>? result,
      {EditorSelection? Function()? remapSelection}) {
    if (result == null) return false;
    // 会话中（拖拽或台词编辑）：不逐次入栈，交由 endDragSession/
    // endTextSession 合并为一条记录
    if (_dragSessionSnapshot == null && _textSessionSnapshot == null) {
      _undoStack.add(_units);
      _redoStack.clear();
    }
    _units = result;
    _selection =
        remapSelection != null ? remapSelection() : _clampSelection(_selection);
    notifyListeners();
    return true;
  }

  bool moveUnitBoundary(int i, int rawMs) =>
      _apply(SegmentationEditOps.moveUnitBoundary(_units, i, rawMs, fps: fps));

  bool moveShotBoundary(int u, int s, int rawMs) => _apply(
      SegmentationEditOps.moveShotBoundary(_units, u, s, rawMs, fps: fps));

  /// 选中单元→splitUnitAt；选中镜头→splitShotAt；无选中→false
  ///
  /// 镜头层只拆**当前选中的那个镜头**（评审 Critical 2）：此前这里把
  /// `sel.shotIndex` 丢掉了，域函数便自己去找"包含播放头的"镜头，导致用户
  /// 选中 S1、播放头停在 S3 时点「拆分」会拆掉 S3。现在播放头不落在所选
  /// 镜头内时域函数返回 null，本方法返回 false，由上层
  /// （WorkbenchBody._splitAtPlayhead）弹 SnackBar 提示。
  bool splitSelectedAt(int rawMs) {
    final sel = _selection;
    if (sel == null) return false;
    final shotIndex = sel.shotIndex;
    if (shotIndex == null) {
      return _apply(SegmentationEditOps.splitUnitAt(_units, sel.unitIndex, rawMs,
          fps: fps, sentences: sentences));
    }
    return _apply(SegmentationEditOps.splitShotAt(_units, sel.unitIndex, rawMs,
        fps: fps, shotIndex: shotIndex));
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
      return _apply(SegmentationEditOps.mergeUnitWithPrevious(_units, u),
          remapSelection: () => EditorSelection.unit(u - 1));
    }
    final u = sel.unitIndex;
    final s = sel.shotIndex!;
    return _apply(SegmentationEditOps.mergeShotWithPrevious(_units, u, s),
        remapSelection: () => EditorSelection.shot(u, s - 1));
  }

  /// ±N 帧步进调整选中对象的边缘：
  /// - 选中单元：startEdge=true 调整与前一单元的边界（moveUnitBoundary(unitIndex-1, ...)，
  ///   首单元返回 false）；startEdge=false 调整与后一单元的边界
  ///   （moveUnitBoundary(unitIndex, ...)，末单元返回 false）
  /// - 选中镜头：同理在单元内换算为 moveShotBoundary
  /// 目标 ms = 当前边界 + frames*frameMs（frames 可为负，表示反方向）
  bool nudgeSelectedEdge({required bool startEdge, required int frames}) {
    final sel = _clampSelection(_selection);
    if (sel == null) return false;
    final delta = frames * SegmentationEditOps.frameMs(fps);

    if (sel.shotIndex == null) {
      final u = sel.unitIndex;
      // 双保险：即便 selection 因某种原因未被及时清理，这里也不会越界解引用
      if (u < 0 || u >= _units.length) return false;
      if (startEdge) {
        if (u <= 0) return false;
        final target = _units[u].startMs + delta;
        return moveUnitBoundary(u - 1, target);
      } else {
        if (u >= _units.length - 1) return false;
        final target = _units[u].endMs + delta;
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
      final target = shots[s].startMs + delta;
      return moveShotBoundary(u, s - 1, target);
    } else {
      if (s >= shots.length - 1) return false;
      final target = shots[s].endMs + delta;
      return moveShotBoundary(u, s, target);
    }
  }

  bool updateTranscript(int u, String text) {
    if (u < 0 || u >= _units.length) return false;
    return _apply(SegmentationEditOps.updateTranscript(_units, u, text));
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    final previous = _undoStack.removeLast();
    _redoStack.add(_units);
    _units = previous;
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
    _selection = _clampSelection(_selection);
    notifyListeners();
  }
}
