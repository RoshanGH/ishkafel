import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../core/log/app_log.dart';
import '../../core/miaoa/candidate_probe.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/renew_task.dart';
import '../../core/playback/media_kit_playback.dart';
import '../../core/playback/noop_playback_controller.dart';
import '../../core/playback/playback_controller.dart';
import '../../core/replacement/replacement_plan.dart';
import '../tasks/task_list_controller.dart';
import '../workbench/player_panel.dart';
import 'candidate_panel.dart';
import 'candidate_search_controller.dart';
import 'picking_bottom_bar.dart';
import 'picking_chrome.dart';
import 'picking_controller.dart';
import 'picking_messages.dart';
import 'picking_scope.dart';
import 'picking_unit_list.dart';
import 'tag_id_resolver.dart';

/// 审片台阶段②「替换选材」页面。
///
/// 装配三件事，各自的状态互不牵连：
/// - [PickingController]：替换方案（两级互斥 + 因子），改动只重建关心它的区域；
/// - [CandidateSearchController]：候选检索与规格探测（并发 + 渐进填充）；
/// - [PlaybackController]：原片 / 候选预览两个播放源。
///
/// 播放位置每秒变化 30 次，一律经 [PlayerPanel] 内部的 ValueNotifier 消费，
/// **不用页面级 setState 接收**——阶段①因此每 tick 白付 10~12ms。
class PickingPage extends ConsumerStatefulWidget {
  final RenewTask task;

  /// 测试注入；缺省构造真实播放器（失败则降级为无播放模式并给出可见提示）
  final PlaybackController Function()? playbackFactory;
  final MiaoaContentService? contentService;
  final CandidateProbe? candidateProbe;
  final MiaoaTagService? tagService;

  const PickingPage({
    super.key,
    required this.task,
    this.playbackFactory,
    this.contentService,
    this.candidateProbe,
    this.tagService,
  });

  @override
  ConsumerState<PickingPage> createState() => _PickingPageState();
}

/// 播放器当前播的是哪一路
enum _PreviewSource { original, candidate }

class _PickingPageState extends ConsumerState<PickingPage> {
  late final PickingController _picking;
  late final CandidateSearchController _search;
  late final TagIdResolver _tagResolver;
  PlaybackController? _playback;
  Widget? _videoWidget;
  bool _playbackDegraded = false;

  CandidateSearchMode _searchMode = CandidateSearchMode.tag;
  _PreviewSource _preview = _PreviewSource.original;

  /// 上一次检索用的作用域指纹：单元/镜头/检索方式没变就不重复检索
  String? _lastSearchKey;

  @override
  void initState() {
    super.initState();
    _picking = PickingController(
      units: widget.task.units ?? const [],
      initial: widget.task.replacements,
    )..addListener(_onPickingChanged);
    _search = CandidateSearchController(
      service: widget.contentService ?? MiaoaContentService(),
      probe: widget.candidateProbe ?? CandidateProbe(),
    );
    _tagResolver = TagIdResolver(widget.tagService ?? MiaoaTagService());

    final playback = _resolvePlayback();
    _playback = playback;
    if (playback is MediaKitPlaybackController) {
      _videoWidget = playback.buildVideoWidget();
    }
    unawaited(playback.open(widget.task.sourcePath));
    unawaited(_loadTagVocabulary());
  }

  /// 与阶段①同款降级：构造真实播放器失败时退到无播放模式，并置顶一条**用户
  /// 可见**的提示条，而不是静默显示占位图标。只捕获 `Exception`，`Error`
  /// 子类（编程错误）继续抛出。
  PlaybackController _resolvePlayback() {
    final factory = widget.playbackFactory ?? MediaKitPlaybackController.new;
    try {
      return factory();
    } on Exception catch (e) {
      AppLog.warn('阶段②播放器初始化失败，改以无播放模式运行：$e');
      _playbackDegraded = true;
      return NoopPlaybackController();
    }
  }

  /// 标签表拉取失败不阻断页面：候选面板会把标签检索标为不可用并说明原因，
  /// 画面描述检索照常可用。
  Future<void> _loadTagVocabulary() async {
    final group = widget.task.shotTagGroup;
    if (group == null) return;
    await _tagResolver.load(group.id);
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _picking.removeListener(_onPickingChanged);
    _picking.dispose();
    _search.dispose();
    unawaited(_playback?.dispose());
    super.dispose();
  }

  PickingScope get _scope => PickingScope.from(
        picking: _picking,
        resolver: _tagResolver,
        shotTagGroup: widget.task.shotTagGroup,
      );

  /// 方案/选中变化后按需重新检索（同一作用域不重复打网络）
  void _onPickingChanged() {
    if (!mounted) return;
    setState(_syncSearchMode);
    unawaited(_refreshSearchIfNeeded());
  }

  /// 标签不可用时自动落到画面描述——把一个用不了的检索方式选中着，
  /// 面板就永远是空的，用户不知道该做什么
  void _syncSearchMode() {
    if (_searchMode == CandidateSearchMode.tag &&
        _scope.tagUnavailableText != null) {
      _searchMode = CandidateSearchMode.description;
    }
  }

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
    if (_picking.discardsSelectionsWhenSwitchingTo(mode)) {
      final confirmed = await showDiscardSelectionDialog(context);
      if (!mounted || confirmed != true) return;
    }
    _picking.setMode(mode);
  }

  /// 当前可预览的候选：作用域里第一个被勾选的那条
  CandidateEntry? get _previewEntry {
    for (final entry in _search.entries) {
      if (_picking.isCandidateSelected(entry.material.id)) return entry;
    }
    return null;
  }

  Future<void> _switchPreview(_PreviewSource source) async {
    final playback = _playback;
    if (playback == null || source == _preview) return;
    final url = source == _PreviewSource.original
        ? widget.task.sourcePath
        : _previewEntry?.material.previewUrl;
    if (url == null) return;
    setState(() => _preview = source);
    await playback.open(url);
  }

  /// 保存替换方案。失败必须让用户看见——静默失败等于用户白挑了一遍。
  Future<bool> _savePlan() async {
    try {
      await ref
          .read(taskListProvider.notifier)
          .savePickingPlan(widget.task, _picking.replacements);
      _picking.markSaved();
      return true;
    } catch (e) {
      AppLog.warn('替换方案落库失败（taskId=${widget.task.id}）：$e');
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('替换方案保存失败，请检查磁盘空间后重试'),
        backgroundColor: AppColors.red,
      ));
      return false;
    }
  }

  /// 「进入矩阵导出」：阶段③尚未开放，但方案先存下来，并如实说明现在能到哪一步
  Future<void> _onEnterExport() async {
    final saved = await _savePlan();
    if (!mounted || !saved) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(stage3UnavailableNotice)));
  }

  Future<void> _onBackToCut() async {
    if (_picking.dirty) {
      final saved = await _savePlan();
      if (!mounted || !saved) return;
    }
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final playback = _playback;
    if (playback == null || _picking.units.isEmpty) {
      return const PickingUnavailableScaffold();
    }
    final videoInfo = widget.task.videoInfo;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: PickingTopBar(
          task: widget.task, onBack: () => Navigator.of(context).maybePop()),
      body: Column(
        children: [
          if (_playbackDegraded) const PickingPlaybackDegradedBanner(),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: 290,
                  child: PickingUnitList(
                      controller: _picking, fps: videoInfo?.fps ?? 30),
                ),
                const VerticalDivider(width: 1, color: AppColors.border),
                Expanded(child: _buildPlayerColumn(playback, videoInfo?.fps ?? 30)),
                const VerticalDivider(width: 1, color: AppColors.border),
                SizedBox(
                  width: 430,
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_picking, _search]),
                    builder: (context, _) => CandidatePanel(
                      picking: _picking,
                      search: _search,
                      scope: _scope,
                      searchMode: _searchMode,
                      onSearchModeChanged: _onSearchModeChanged,
                      onModeChanged: _onModeChanged,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: _picking,
        builder: (context, _) => PickingBottomBar(
          controller: _picking,
          onBackToCut: _onBackToCut,
          onEnterExport:
              exportBlockedReason(_picking.plan) == null ? _onEnterExport : null,
        ),
      ),
    );
  }

  Widget _buildPlayerColumn(PlaybackController playback, double fps) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: AnimatedBuilder(
            animation: Listenable.merge([_picking, _search]),
            builder: (context, _) => PreviewSourceSegment(
              candidateEnabled: _previewEntry != null,
              showingCandidate: _preview == _PreviewSource.candidate,
              onOriginal: () => _switchPreview(_PreviewSource.original),
              onCandidate: () => _switchPreview(_PreviewSource.candidate),
            ),
          ),
        ),
        Expanded(
          child: PlayerPanel(
            playback: playback,
            videoWidget: _videoWidget,
            durationMs:
                widget.task.videoInfo?.duration.inMilliseconds ?? 0,
            fps: fps,
          ),
        ),
      ],
    );
  }
}
