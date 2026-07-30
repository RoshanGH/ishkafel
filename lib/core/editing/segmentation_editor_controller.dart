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
class SegmentationEditorController extends ChangeNotifier {
  final int durationMs;
  final double fps;
  final List<AsrSentence> sentences;

  final List<SemanticUnit> _initialUnits;
  List<SemanticUnit> _units;
  EditorSelection? _selection;

  final List<List<SemanticUnit>> _undoStack = [];
  final List<List<SemanticUnit>> _redoStack = [];

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

  void select(EditorSelection? s) {
    _selection = s;
    notifyListeners();
  }

  /// 将纯函数结果应用到当前状态：成功则入栈、清 redo、notify；失败返回 false
  bool _apply(List<SemanticUnit>? result) {
    if (result == null) return false;
    _undoStack.add(_units);
    _redoStack.clear();
    _units = result;
    notifyListeners();
    return true;
  }

  bool moveUnitBoundary(int i, int rawMs) =>
      _apply(SegmentationEditOps.moveUnitBoundary(_units, i, rawMs, fps: fps));

  bool moveShotBoundary(int u, int s, int rawMs) => _apply(
      SegmentationEditOps.moveShotBoundary(_units, u, s, rawMs, fps: fps));

  /// 选中单元→splitUnitAt；选中镜头→splitShotAt；无选中→false
  bool splitSelectedAt(int rawMs) {
    final sel = _selection;
    if (sel == null) return false;
    if (sel.shotIndex == null) {
      return _apply(SegmentationEditOps.splitUnitAt(_units, sel.unitIndex, rawMs,
          fps: fps, sentences: sentences));
    }
    return _apply(
        SegmentationEditOps.splitShotAt(_units, sel.unitIndex, rawMs, fps: fps));
  }

  /// 按选中层分派：选中单元→mergeUnitWithPrevious；选中镜头→mergeShotWithPrevious
  bool mergeSelectedWithPrevious() {
    final sel = _selection;
    if (sel == null) return false;
    if (sel.shotIndex == null) {
      return _apply(SegmentationEditOps.mergeUnitWithPrevious(_units, sel.unitIndex));
    }
    return _apply(SegmentationEditOps.mergeShotWithPrevious(
        _units, sel.unitIndex, sel.shotIndex!));
  }

  /// ±N 帧步进调整选中对象的边缘：
  /// - 选中单元：startEdge=true 调整与前一单元的边界（moveUnitBoundary(unitIndex-1, ...)，
  ///   首单元返回 false）；startEdge=false 调整与后一单元的边界
  ///   （moveUnitBoundary(unitIndex, ...)，末单元返回 false）
  /// - 选中镜头：同理在单元内换算为 moveShotBoundary
  /// 目标 ms = 当前边界 + frames*frameMs（frames 可为负，表示反方向）
  bool nudgeSelectedEdge({required bool startEdge, required int frames}) {
    final sel = _selection;
    if (sel == null) return false;
    final delta = frames * SegmentationEditOps.frameMs(fps);

    if (sel.shotIndex == null) {
      final u = sel.unitIndex;
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
    final s = sel.shotIndex!;
    final shots = _units[u].shots;
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
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    final next = _redoStack.removeLast();
    _undoStack.add(_units);
    _units = next;
    notifyListeners();
  }
}
