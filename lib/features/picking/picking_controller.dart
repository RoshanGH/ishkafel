import '../../core/replacement/unit_base.dart';
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

  /// 这个单元**固定过底片**：它的镜头是按那条素材切出来的。
  ///
  /// 数据上它仍然是「整体替换、选了一条」，但那一条的角色已经从「顶替这一段
  /// 的素材」变成「这一段的底片」——镜头替换换的是底片上的某一刀，两者不再
  /// 互斥（见 `docs/superpowers/specs/2026-09-14-底片-design.md`）
  bool get currentBasePinned {
    final unit = currentUnit;
    return unit != null && hasOwnBaseShots(unit);
  }

  /// 镜头级替换是否被锁定：已经在整体替换里选过候选。
  ///
  /// **固定过底片的单元不锁**——它的那一条是底片，镜头替换换的是底片上的
  /// 某一刀。锁住的话，人切完分镜却给不了任何一镜挑素材，整件事就白做了
  bool get perShotLocked =>
      !currentBasePinned &&
      currentMode == ReplacementMode.whole &&
      currentReplacement.wholeCandidateIds.isNotEmpty;

  /// 反过来，**固定过底片之后整体替换那一档要锁死**：那一条已经是底片，
  /// 在这里换掉它，切好的镜头就全指向另一条素材的时间点。
  /// 要换底片去属性面板走「换一张底片」——那条路会把作废什么说清楚
  bool get wholeLockedByBase => currentBasePinned;

  /// 切到 [mode] 会不会丢弃已选候选。UI 据此弹二次确认——直接清掉是破坏性
  /// 操作，用户点错一次就得重挑一遍。
  bool discardsSelectionsWhenSwitchingTo(ReplacementMode mode) {
    if (mode == currentMode) return false;
    // **固定过底片的单元切到镜头替换，什么都不丢**：那一条候选是底片，
    // 记在单元身上（[SemanticUnit.baseCandidateId]），不在方案里。
    // 照旧弹「已选候选会被清空」的话，人会以为底片没了而不敢点——
    // 而切过去挑镜头正是切分之后该做的下一步
    if (currentBasePinned && mode == ReplacementMode.perShot) return false;
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
  /// 这条素材已经挑给了**别的位置**的话，返回那个位置（如「U1」「U4 的 S5」）。
  ///
  /// 用来在挑选那一刻当场拦：同一条素材不能在一条成片里出现两次，等到导出
  /// 对话框里才发现组合被去掉一半，就是马后炮
  String? usedElsewhere(int candidateId) {
    for (var i = 0; i < _replacements.length; i++) {
      final r = _replacements[i];
      if (r.wholeCandidateIds.contains(candidateId)) {
        if (i == _selectedUnitIndex && currentMode == ReplacementMode.whole) {
          continue; // 就是当前位置：那是取消勾选，不拦
        }
        return 'U${i + 1}';
      }
      for (final e in r.shotCandidateIds.entries) {
        if (!e.value.contains(candidateId)) continue;
        if (i == _selectedUnitIndex &&
            currentMode == ReplacementMode.perShot &&
            e.key == _selectedShotIndex) {
          continue;
        }
        return 'U${i + 1} 的 S${e.key + 1}';
      }
    }
    return null;
  }

  /// 上一次 toggle 被拦下的原因（人话）。取一次就清空——它是给 SnackBar
  /// 用的一次性消息，不是状态
  String? _blockedMessage;
  String? takeBlockedMessage() {
    final message = _blockedMessage;
    _blockedMessage = null;
    return message;
  }

  void toggleCandidate(int candidateId) {
    // 勾上（而不是取消）一条已经用在别处的素材：当场拦住并说清去哪儿解
    if (!isCandidateSelected(candidateId)) {
      if (usedElsewhere(candidateId) case final where?) {
        _blockedMessage = '这条素材已经挑给 $where 了。'
            '同一条素材不能在一条成片里用两次——先去那边取消，才能挑到这里';
        notifyListeners();
        return;
      }
    }
    switch (currentMode) {
      case ReplacementMode.keepOriginal:
        return;
      case ReplacementMode.whole:
        _replace(
          _selectedUnitIndex,
          UnitReplacement.whole(
            _toggled(currentReplacement.wholeCandidateIds, candidateId),
            // 取消勾选的正好是预览版时，构造函数会自动退回第一个
            previewId: currentReplacement.wholePreviewId,
          ),
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
        _replace(
            _selectedUnitIndex,
            UnitReplacement.perShot(byShot,
                previewIds: currentReplacement.shotPreviewIds));
    }
  }

  /// 把某个候选设为**预览版**：播放时这一段放的就是它。
  ///
  /// 导出仍然会把选中的候选都用上（一个一条变体），预览只能放一个——
  /// 这个标记就是「放哪一个」。只对已经勾选的候选生效。
  void setPreviewCandidate(int candidateId) {
    if (!isCandidateSelected(candidateId)) return;
    switch (currentMode) {
      case ReplacementMode.keepOriginal:
        return;
      case ReplacementMode.whole:
        _replace(
          _selectedUnitIndex,
          UnitReplacement.whole(currentReplacement.wholeCandidateIds,
              previewId: candidateId),
        );
      case ReplacementMode.perShot:
        final shot = _selectedShotIndex;
        if (shot == null) return;
        _replace(
          _selectedUnitIndex,
          UnitReplacement.perShot(currentReplacement.shotCandidateIds,
              previewIds: {
                ...currentReplacement.shotPreviewIds,
                shot: candidateId,
              }),
        );
    }
  }

  /// 当前作用域里预览播的是哪一个候选；没选候选时为 null
  int? get previewCandidateId => switch (currentMode) {
        ReplacementMode.keepOriginal => null,
        ReplacementMode.whole => currentReplacement.wholePreviewId,
        ReplacementMode.perShot => _selectedShotIndex == null
            ? null
            : currentReplacement.shotPreviewId(_selectedShotIndex!),
      };

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
