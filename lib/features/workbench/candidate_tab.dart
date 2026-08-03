import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/miaoa/candidate_probe.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/replacement/replacement_plan.dart';
import '../picking/candidate_panel.dart';
import '../picking/candidate_search_controller.dart';
import '../picking/picking_controller.dart';
import '../picking/picking_widgets.dart';
import '../picking/picking_scope.dart';
import '../picking/tag_id_resolver.dart';

/// 工作台右栏的「替换素材」视图。
///
/// 由原阶段②整页收缩而来。整页里的左栏（单元列表）和播放器都不再需要——
/// 工作台本来就有时间线和播放器，选中谁就是在给谁挑素材。因此这里**不持有
/// 自己的选中**，而是跟随 [editor] 的 selection：在时间线上点 U3，右栏
/// 就在给 U3 挑；点到 S2，作用域收窄到那个视觉镜头。
///
/// 仍然持有的三件状态，各自的变化互不牵连：
/// - [PickingController]：替换方案（两级互斥 + 因子）
/// - [CandidateSearchController]：候选检索与规格探测（并发 + 渐进填充）
/// - [TagIdResolver]：标签名 → miaoa 标签 id 的映射表
class CandidateTab extends StatefulWidget {
  final SegmentationEditorController editor;
  final List<TagGroupRef> shotTagGroups;

  /// 已保存的替换方案
  final List<UnitReplacement>? initialReplacements;

  /// 方案有任何改动就上抛，由工作台落库（与切分改动同一条自动保存通路）
  final ValueChanged<List<UnitReplacement>> onReplacementsChanged;

  /// 只读回看：已导出的任务不能再改方案
  final bool readOnly;

  /// 测试注入
  final MiaoaContentService? contentService;
  final CandidateProbe? candidateProbe;
  final MiaoaTagService? tagService;

  const CandidateTab({
    super.key,
    required this.editor,
    required this.shotTagGroups,
    required this.onReplacementsChanged,
    this.initialReplacements,
    this.readOnly = false,
    this.contentService,
    this.candidateProbe,
    this.tagService,
  });

  @override
  State<CandidateTab> createState() => CandidateTabState();
}

class CandidateTabState extends State<CandidateTab> {
  late PickingController _picking;
  late final CandidateSearchController _search;
  late final TagIdResolver _tagResolver;

  CandidateSearchMode _searchMode = CandidateSearchMode.tag;

  /// 上一次检索用的作用域指纹：单元/镜头/检索方式没变就不重复检索
  String? _lastSearchKey;

  /// 上一次见到的单元数：编辑到增删单元时方案要跟着重建
  late int _unitCount;

  @override
  void initState() {
    super.initState();
    _picking = _buildPicking(widget.initialReplacements);
    _unitCount = widget.editor.units.length;
    _search = CandidateSearchController(
      service: widget.contentService ?? MiaoaContentService(),
      probe: widget.candidateProbe ?? CandidateProbe(),
    );
    _tagResolver = TagIdResolver(widget.tagService ?? MiaoaTagService());

    widget.editor.addListener(_onEditorChanged);
    // 挂载时先对齐一次当前选中。右栏切回「替换素材」时这个面板是重新挂载的，
    // 只订阅「之后的变化」会让它停在 U1——而用户早就在时间线上走到别处了。
    _syncSelectionFromEditor();
    _syncSearchMode();
    unawaited(_loadTagVocabulary());
  }

  PickingController _buildPicking(List<UnitReplacement>? initial) =>
      PickingController(units: widget.editor.units, initial: initial)
        ..addListener(_onPickingChanged);

  /// 标签表拉取失败不阻断：候选面板会把标签检索标为不可用并说明原因，
  /// 画面描述检索照常可用。
  Future<void> _loadTagVocabulary() async {
    if (widget.shotTagGroups.isEmpty) return;
    await _tagResolver.loadAll([for (final g in widget.shotTagGroups) g.id]);
    if (!mounted) return;
    // 标签表是异步拉的：刚进来看着可用、拉完（或拉失败）才知道到底行不行，
    // 这一刻同样不能把点不动的段留在选中态
    _syncSearchMode();
    setState(() {});
    unawaited(_refreshSearchIfNeeded());
  }

  @override
  void dispose() {
    widget.editor.removeListener(_onEditorChanged);
    _picking.removeListener(_onPickingChanged);
    _picking.dispose();
    _search.dispose();
    super.dispose();
  }

  /// 工作台的选中变了就跟着走。
  ///
  /// 编辑器每帧都可能 notify（拖边界、改台词），因此这里只在**选中或单元结构
  /// 真的变了**时才动手——[_refreshSearchIfNeeded] 里的指纹比对是第二道闸。
  void _onEditorChanged() {
    if (!mounted) return;
    if (widget.editor.units.length != _unitCount) {
      // 增删单元会让按下标存的方案整体错位。方案是按 index 存的，重建时
      // 沿用不下来的那部分只能丢——「改了 U 要不要清掉它挑好的素材」这个
      // 问题由工作台在编辑后询问用户，这里只保证不越界。
      _unitCount = widget.editor.units.length;
      final old = _picking;
      _picking = _buildPicking(old.replacements);
      old.removeListener(_onPickingChanged);
      old.dispose();
    }
    _syncSelectionFromEditor();
    _onPickingChanged();
  }

  /// 把工作台的选中灌进方案控制器。
  ///
  /// 选中 U 时不动镜头下标：镜头级模式下 [PickingController.selectUnit] 会
  /// 自己落到第一个镜头，传 null 反而把它清掉，勾选就没有落点了。
  void _syncSelectionFromEditor() {
    final sel = widget.editor.selection;
    if (sel == null) return;
    _picking.selectUnit(sel.unitIndex);
    if (sel.shotIndex != null) _picking.selectShot(sel.shotIndex);
  }

  /// 方案/选中变化后按需重新检索（同一作用域不重复打网络），并把改动落库。
  void _onPickingChanged() {
    if (!mounted) return;
    // 勾一条候选就是一次改动，直接落库：工作台里没有「未保存」这回事。
    // markSaved 会再 notify 一次，但那一次 dirty 已是 false，不会递归。
    if (_picking.dirty && !widget.readOnly) _emit();
    final before = _searchMode;
    _syncSearchMode();
    if (before != _searchMode) setState(() {});
    unawaited(_refreshSearchIfNeeded());
  }

  /// 标签不可用时自动落到画面描述——把一个用不了的检索方式选中着，
  /// 面板就永远是空的，用户不知道该做什么
  void _syncSearchMode() {
    if (_searchMode != CandidateSearchMode.tag) return;
    final scope = _scope;
    // 「还在读标签表」不是「用不了」：这一刻切走是不可逆的（不会再切回来），
    // 拉完一切正常时用户就白白丢了主路径
    if (scope.tagPending) return;
    if (scope.tagUnavailableText != null) {
      _searchMode = CandidateSearchMode.description;
    }
  }

  PickingScope get _scope => PickingScope.from(
        picking: _picking,
        resolver: _tagResolver,
        shotTagGroups: widget.shotTagGroups,
      );

  Future<void> _refreshSearchIfNeeded() async {
    if (_picking.currentMode == ReplacementMode.keepOriginal) {
      _lastSearchKey = null;
      _search.clear();
      return;
    }
    final key = '${_picking.selectedUnitIndex}/${_picking.selectedShotIndex}/'
        '${_searchMode.name}/${_picking.currentMode.name}';
    if (key == _lastSearchKey) return;
    _lastSearchKey = key;
    await _runSearch();
  }

  Future<void> _runSearch() async {
    final scope = _scope;
    switch (_searchMode) {
      case CandidateSearchMode.tag:
        await _search.searchByTags(tagIds: scope.tagIds);
      case CandidateSearchMode.description:
        await _search.searchByDescription(scope.descriptionKeyword);
      case CandidateSearchMode.image:
        // 首帧搜图未接通（原片这一帧不在素材库里，没有可用的检索键）
        _search.clear();
    }
  }

  void _onSearchModeChanged(CandidateSearchMode mode) {
    if (mode == _searchMode) return;
    setState(() => _searchMode = mode);
    unawaited(_refreshSearchIfNeeded());
  }

  /// 切换替换模式。会丢弃已选候选时先弹二次确认——选材是体力活，
  /// 点错一次就得重挑一遍。
  Future<void> _onModeChanged(ReplacementMode mode) async {
    if (widget.readOnly) return;
    if (_picking.discardsSelectionsWhenSwitchingTo(mode)) {
      final confirmed = await showDiscardSelectionDialog(context);
      if (!mounted || confirmed != true) return;
    }
    _picking.setMode(mode);
    // setMode 切到镜头级会强制落到第一个镜头。用户是在时间线上点着 S3 才来
    // 选镜头级替换的，面板却跳去 S1——选中权归时间线，这里把它拿回来。
    _syncSelectionFromEditor();
  }

  /// 把方案交回工作台落库
  void _emit() {
    widget.onReplacementsChanged(_picking.replacements);
    _picking.markSaved();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([_picking, _search]),
        builder: (context, _) => CandidatePanel(
          picking: _picking,
          search: _search,
          scope: _scope,
          searchMode: _searchMode,
          onSearchModeChanged: _onSearchModeChanged,
          onModeChanged: _onModeChanged,
        ),
      );
}
