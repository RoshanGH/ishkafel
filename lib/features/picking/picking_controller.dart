import 'package:flutter/foundation.dart';

import '../../core/models/semantic_unit.dart';
import '../../core/replacement/replacement_plan.dart';

/// 阶段②「替换选材」的方案状态机。
///
/// 只管方案本身与选中位置，不管检索、不管播放、不碰 Widget——候选素材的
/// 检索与规格探测在 `candidate_search_controller.dart`，两者由页面组装。
/// 这样这套「两级互斥 + 因子」的规则可以完全脱离 UI 单测。
///
/// 全程不可变：每次改动都构造新的 [UnitReplacement] 与新的列表，
/// 不就地修改已有对象，也不把可变集合暴露给外部。
class PickingController extends ChangeNotifier {
  final List<SemanticUnit> units;

  List<UnitReplacement> _replacements;
  int _selectedUnitIndex = 0;
  int? _selectedShotIndex;
  bool _dirty = false;

  PickingController({
    required List<SemanticUnit> units,
    List<UnitReplacement>? initial,
  })  : units = List.unmodifiable(units),
        _replacements = _normalize(initial, units.length) {
    _selectedShotIndex = _defaultShotIndex(0);
  }

  /// 历史方案与当前单元数对齐：切分被改动过之后单元数会变，少的补「保留原片」、
  /// 多的截断。不这样做的话，下标一错位，用户会看到别的单元的选择。
  static List<UnitReplacement> _normalize(
      List<UnitReplacement>? initial, int unitCount) {
    final source = initial ?? const <UnitReplacement>[];
    return List.unmodifiable([
      for (var i = 0; i < unitCount; i++)
        i < source.length ? source[i] : UnitReplacement.keepOriginal(),
    ]);
  }

  /// 按单元顺序排列的替换方案（只读）
  List<UnitReplacement> get replacements => _replacements;

  int get selectedUnitIndex => _selectedUnitIndex;

  /// 当前选中的视觉镜头下标；非镜头级模式下为 null
  int? get selectedShotIndex => _selectedShotIndex;

  /// 有未保存的改动（页面据此决定离开时是否确认、是否需要落库）
  bool get dirty => _dirty;

  ReplacementPlan get plan => ReplacementPlan(_replacements);

  SemanticUnit? get currentUnit =>
      units.isEmpty ? null : units[_selectedUnitIndex];

  UnitReplacement get currentReplacement => _replacements.isEmpty
      ? UnitReplacement.keepOriginal()
      : _replacements[_selectedUnitIndex];

  ReplacementMode get currentMode => currentReplacement.mode;

  /// 当前单元的视觉镜头数
  int get currentShotCount => currentUnit?.shots.length ?? 0;

  /// 镜头级替换是否可用：没有视觉镜头就没有可替换的对象
  bool get canUsePerShot => currentShotCount > 0;

  /// 整体替换是否被锁定（设计稿的 🔒）：已经在镜头级选过候选
  bool get wholeLocked =>
      currentMode == ReplacementMode.perShot &&
      currentReplacement.shotCandidateIds.values.any((v) => v.isNotEmpty);

  /// 镜头级替换是否被锁定：已经在整体替换里选过候选
  bool get perShotLocked =>
      currentMode == ReplacementMode.whole &&
      currentReplacement.wholeCandidateIds.isNotEmpty;

  /// 切到 [mode] 会不会丢弃已选候选。UI 据此弹二次确认——直接清掉是破坏性
  /// 操作，用户点错一次就得重挑一遍。
  bool discardsSelectionsWhenSwitchingTo(ReplacementMode mode) {
    if (mode == currentMode) return false;
    return currentReplacement.factor > 1 ||
        currentReplacement.wholeCandidateIds.isNotEmpty ||
        currentReplacement.shotCandidateIds.values.any((v) => v.isNotEmpty);
  }

  /// 当前作用域（整体替换看单元、镜头级看选中的那个镜头）已选候选数
  int get selectedCountInScope => _scopeSelection().length;

  bool isCandidateSelected(int candidateId) =>
      _scopeSelection().contains(candidateId);

  List<int> _scopeSelection() {
    switch (currentMode) {
      case ReplacementMode.keepOriginal:
        return const [];
      case ReplacementMode.whole:
        return currentReplacement.wholeCandidateIds;
      case ReplacementMode.perShot:
        final shot = _selectedShotIndex;
        if (shot == null) return const [];
        return currentReplacement.shotCandidateIds[shot] ?? const [];
    }
  }

  /// 选中另一个台词语义单元。越界下标忽略（脏数据/竞态兜底，不崩）。
  void selectUnit(int index) {
    if (index < 0 || index >= units.length || index == _selectedUnitIndex) {
      return;
    }
    _selectedUnitIndex = index;
    _selectedShotIndex = _defaultShotIndex(index);
    notifyListeners();
  }

  /// 选中某个视觉镜头。非镜头级模式下无意义，忽略。
  void selectShot(int? shotIndex) {
    if (currentMode != ReplacementMode.perShot) return;
    if (shotIndex != null &&
        (shotIndex < 0 || shotIndex >= currentShotCount)) {
      return;
    }
    if (shotIndex == _selectedShotIndex) return;
    _selectedShotIndex = shotIndex;
    notifyListeners();
  }

  /// 切换当前单元的替换模式。
  ///
  /// 两级互斥由 [UnitReplacement] 的工厂在类型层面保证：切到哪一边，另一边的
  /// 选择就被清空，组合数不会把两边都乘进去。
  void setMode(ReplacementMode mode) {
    if (units.isEmpty || mode == currentMode) return;
    if (mode == ReplacementMode.perShot && !canUsePerShot) return;
    final next = switch (mode) {
      ReplacementMode.keepOriginal => UnitReplacement.keepOriginal(),
      ReplacementMode.whole => UnitReplacement.whole(const []),
      ReplacementMode.perShot => UnitReplacement.perShot(const {}),
    };
    _selectedShotIndex = mode == ReplacementMode.perShot ? 0 : null;
    _replace(_selectedUnitIndex, next);
  }

  /// 勾选/取消勾选一个候选素材，作用在当前作用域上。
  /// 保留原片模式下不生效——没有可放置的位置，静默忽略优于凭空改模式。
  void toggleCandidate(int candidateId) {
    switch (currentMode) {
      case ReplacementMode.keepOriginal:
        return;
      case ReplacementMode.whole:
        _replace(
          _selectedUnitIndex,
          UnitReplacement.whole(
              _toggled(currentReplacement.wholeCandidateIds, candidateId)),
        );
      case ReplacementMode.perShot:
        final shot = _selectedShotIndex;
        if (shot == null) return;
        final byShot = <int, List<int>>{
          for (final e in currentReplacement.shotCandidateIds.entries)
            e.key: e.value,
          shot: _toggled(
              currentReplacement.shotCandidateIds[shot] ?? const [], candidateId),
        };
        _replace(_selectedUnitIndex, UnitReplacement.perShot(byShot));
    }
  }

  /// 返回新列表，绝不改动传入的那份
  static List<int> _toggled(List<int> current, int id) => current.contains(id)
      ? [
          for (final e in current)
            if (e != id) e,
        ]
      : [...current, id];

  void _replace(int index, UnitReplacement replacement) {
    _replacements = List.unmodifiable([
      for (var i = 0; i < _replacements.length; i++)
        i == index ? replacement : _replacements[i],
    ]);
    _dirty = true;
    notifyListeners();
  }

  /// 落库成功后清除未保存标记
  void markSaved() {
    if (!_dirty) return;
    _dirty = false;
    notifyListeners();
  }

  /// 进入某个单元时的默认镜头选中：镜头级模式落回第一个镜头（停在一个用户
  /// 已经看不见的选中上会让「勾选到底落在哪」变得不可预期），其余模式为 null
  int? _defaultShotIndex(int unitIndex) {
    if (unitIndex < 0 || unitIndex >= _replacements.length) return null;
    final mode = _replacements[unitIndex].mode;
    if (mode != ReplacementMode.perShot) return null;
    return units[unitIndex].shots.isEmpty ? null : 0;
  }
}
