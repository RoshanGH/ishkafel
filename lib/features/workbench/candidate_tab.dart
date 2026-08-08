import 'dart:async';

import 'package:collection/collection.dart';

import 'package:flutter/material.dart';

import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/miaoa/candidate_probe.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/project_ref.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/replacement/replacement_plan.dart';
import '../picking/candidate_panel.dart';
import '../picking/picked_material_store.dart';
import '../picking/picked_media_cache.dart';
import '../picking/picked_tray.dart';
import '../picking/candidate_preview.dart';
import '../../core/log/app_log.dart';
import '../picking/tag_hit_probe.dart';
import '../picking/tag_query_narrowing.dart';
import '../picking/candidate_search_controller.dart';
import '../picking/picking_controller.dart';
import '../picking/picking_widgets.dart';
import '../picking/picking_scope.dart';
import 'search_mode_policy.dart';
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

  /// 台词语义单元标签组：整体替换用这一层的标签当检索键
  final List<TagGroupRef> unitTagGroups;

  /// 已保存的替换方案
  final List<UnitReplacement>? initialReplacements;

  /// 方案有任何改动就上抛，由工作台落库（与切分改动同一条自动保存通路）
  final ValueChanged<List<UnitReplacement>> onReplacementsChanged;

  /// 已挑中素材的落地记录（随任务存盘）。为空表示还没挑过 / 旧任务
  final List<PickedMaterial> pickedMaterials;

  /// 落地记录有变动就上抛，和 [onReplacementsChanged] 走同一条保存通路。
  /// 没接的话托盘照样能画（用内存里那份），只是重开 app 就没了
  final ValueChanged<List<PickedMaterial>>? onPickedMaterialsChanged;

  /// 把一条候选落到盘上（下首帧图）。注入而不是内建：单测不碰网络和磁盘
  final PickedMaterialStore? pickedStore;

  /// 把已选素材的**视频本体**固定在本地。为空表示不固定——预览和导出仍然
  /// 能按 id 现取，只是素材库那边一动就会出事
  final PickedMediaCache? mediaCache;

  /// 只读回看：已导出的任务不能再改方案
  final bool readOnly;

  /// 在哪个项目里找素材；null 表示不限项目（我的全部项目聚合）
  final ProjectRef? project;

  /// 试看一条素材。缺省弹真实播放浮层；测试注入假实现，免得碰 libmpv。
  final CandidatePreviewOpener? onPreview;

  /// 每页多少条。默认 24：台词视图一屏约七条、画面视图约十二条，
  /// 一页翻两三屏是顺手的节奏，再多就变成无尽滚动、找不回刚看过那条了。
  final int pageSize;

  /// 测试注入
  final MiaoaContentService? contentService;
  final CandidateProbe? candidateProbe;
  final MiaoaTagService? tagService;

  const CandidateTab({
    super.key,
    required this.editor,
    required this.shotTagGroups,
    this.unitTagGroups = const [],
    required this.onReplacementsChanged,
    this.pickedMaterials = const [],
    this.onPickedMaterialsChanged,
    this.pickedStore,
    this.mediaCache,
    this.initialReplacements,
    this.readOnly = false,
    this.project,
    this.onPreview,
    this.pageSize = 24,
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

  /// 当前这个模式是程序自动落下来的（标签用不了）还是用户自己点的。
  /// 前者要在标签恢复可用时收回来，后者绝不能被抢走。见 [nextSearchMode]
  bool _modeAutoFellBack = false;
  bool _modeUserPinned = false;

  /// 这一次实际用了哪几个标签、剔掉了哪几个。界面要说清楚——否则用户看到
  /// 结果变了却不知道为什么
  TagQueryPlan? _tagPlan;

  /// 台词 / 画面。整体替换默认台词——那一层换的是「一句话对应的一段画面」
  CandidateView _view = CandidateView.transcript;

  /// 候选卡默认小图：挑素材是「扫一眼过一批」的活，一屏二十几张比八张顺手。
  /// 想看清哪一条就切成大图，或者直接点播放键试看
  bool _compactCards = true;

  /// 逐个标签的命中数：只在搜不到东西、且用户主动点了的时候才去数
  late final TagHitProbe _tagHitProbe =
      TagHitProbe(widget.contentService ?? MiaoaContentService());
  List<TagHit>? _tagHits;
  bool _tagHitsLoading = false;

  /// 上一次检索用的作用域指纹：单元/镜头/检索方式没变就不重复检索
  String? _lastSearchKey;

  /// 上一次见到的单元数：编辑到增删单元时方案要跟着重建
  late int _unitCount;

  /// 已挑中素材的落地记录（候选 id → 记录）。种子来自任务，之后跟着勾选走
  late Map<int, PickedMaterial> _picked;

  /// 正在落地的候选 id：防止同一条被并发写两遍
  final Set<int> _saving = {};

  @override
  void initState() {
    super.initState();
    _picking = _buildPicking(widget.initialReplacements);
    _picked = {for (final m in widget.pickedMaterials) m.id: m};
    _unitCount = widget.editor.units.length;
    _search = CandidateSearchController(
      service: widget.contentService ?? MiaoaContentService(),
      probe: widget.candidateProbe ?? CandidateProbe(),
      projectIds: _projectIds,
      pageSize: widget.pageSize,
    );
    _tagResolver = TagIdResolver(widget.tagService ?? MiaoaTagService());

    widget.mediaCache?.addListener(_onMediaChanged);
    widget.editor.addListener(_onEditorChanged);
    // 挂载时先对齐一次当前选中。右栏切回「替换素材」时这个面板是重新挂载的，
    // 只订阅「之后的变化」会让它停在 U1——而用户早就在时间线上走到别处了。
    _syncSelectionFromEditor();
    _syncSearchMode();
    unawaited(_loadTagVocabulary());
    // 进面板就把已选素材固定住。只在勾选**变化**时才做的话，打开一条早就
    // 选好的任务什么都不会发生——而那正是最需要提前把素材抓在手里的时候
    unawaited(_syncPicked());
    unawaited(_backfillPicked());
  }

  /// 传给 CLI 的 `--projects`；不限项目时为空
  List<int> get _projectIds =>
      widget.project == null ? const [] : [widget.project!.id];

  @override
  void didUpdateWidget(CandidateTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 用户在「标签组设置」里换了项目：检索范围要当场跟着变，
    // 否则右栏还在按上一个项目的素材给候选
    if (oldWidget.project?.id != widget.project?.id) {
      _search.projectIds = _projectIds;
      unawaited(_refreshSearchIfNeeded());
    }
  }

  PickingController _buildPicking(List<UnitReplacement>? initial) =>
      PickingController(units: widget.editor.units, initial: initial)
        ..addListener(_onPickingChanged);

  /// 标签表拉取失败不阻断：候选面板会把标签检索标为不可用并说明原因，
  /// 画面描述检索照常可用。
  Future<void> _loadTagVocabulary() async {
    // 两层的标签表都要：整体替换按台词语义层的标签搜，镜头替换按画面层的
    final groupIds = {
      for (final g in widget.unitTagGroups) g.id,
      for (final g in widget.shotTagGroups) g.id,
    };
    if (groupIds.isEmpty) return;
    await _tagResolver.loadAll(groupIds);
    if (!mounted) return;
    // 标签表是异步拉的：刚进来看着可用、拉完（或拉失败）才知道到底行不行，
    // 这一刻同样不能把点不动的段留在选中态
    _syncSearchMode();
    setState(() {});
    unawaited(_refreshSearchIfNeeded());
  }

  @override
  void dispose() {
    widget.mediaCache?.removeListener(_onMediaChanged);
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

  void _onMediaChanged() {
    if (mounted) setState(() {});
  }

  /// 把「勾了哪些」和「落地记录」对齐：
  /// - 新勾上的：从当前检索结果里取到素材信息，连首帧图一起落到盘上；
  /// - 取消勾选的：记录和首帧图一起清掉，不留垃圾。
  ///
  /// 只落信息不落视频——见 [PickedMaterialStore] 的说明。
  Future<void> _syncPicked() async {
    final referenced = _referencedCandidateIds();
    // 勾上就把素材本体拉到本地固定住；取消勾选只解除固定，不删文件
    // ——取消常是试错动作，改回来还得重下几十兆（见 [PickedMediaCache]）
    widget.mediaCache?.pinAll(referenced);

    // 先做减法：取消勾选是同步就该看到的
    final dropped = _picked.keys.where((id) => !referenced.contains(id)).toSet();
    if (dropped.isNotEmpty) {
      setState(() => _picked = {
            for (final e in _picked.entries)
              if (referenced.contains(e.key)) e.key: e.value,
          });
      widget.pickedStore?.prune(referenced);
      _emitPicked();
    }

    // 再做加法：一条条落地，落完一条刷新一条（首帧图要下载，不能等齐了再画）
    for (final id in referenced) {
      if (_picked.containsKey(id) || _saving.contains(id)) continue;
      final entry = _search.entries
          .firstWhereOrNull((e) => e.material.id == id);
      if (entry == null) continue; // 不在这一页结果里，交给 [_backfillPicked]
      _saving.add(id);
      await _store(entry.material, entry.spec?.durationMs);
    }
  }

  /// 落地一条，成功与否都要出结果——首帧图下不下得来是次要的，
  /// 「我选了哪几条」不能因为一张图丢掉
  Future<void> _store(CandidateMaterial material, int? durationMs) async {
    PickedMaterial record;
    try {
      final store = widget.pickedStore;
      record = store == null
          ? PickedMaterial(
              id: material.id,
              name: material.name,
              voiceover: material.voiceover,
              sceneDescription: material.sceneDescription,
              durationMs: durationMs)
          : await store.save(material, durationMs: durationMs);
    } catch (e) {
      AppLog.warn('已选素材 ${material.id} 落地失败：$e');
      record = PickedMaterial(id: material.id, name: material.name);
    } finally {
      _saving.remove(material.id);
    }
    if (!mounted) return;
    // 落地期间可能已经被取消勾选了，那就别再写回去
    if (!_referencedCandidateIds().contains(material.id)) return;
    setState(() => _picked = {..._picked, material.id: record});
    _emitPicked();
  }

  /// 旧任务里只有一串 id、没有落地记录：按 id 去库里补一次。
  /// 补完就写盘，之后再进来就不用连网了。
  Future<void> _backfillPicked() async {
    final missing = _referencedCandidateIds()
        .where((id) => !_picked.containsKey(id) && !_saving.contains(id))
        .toList();
    if (missing.isEmpty) return;
    final service = widget.contentService ?? MiaoaContentService();
    for (final id in missing) {
      _saving.add(id);
      try {
        final material = await service.fetchById(id);
        if (material == null) {
          _saving.remove(id);
          // 素材在库里被删了也要占个位——凭空少一条比显示一条「读不出来」更糟
          if (!mounted) return;
          setState(() => _picked = {
                ..._picked,
                id: PickedMaterial(id: id, name: '素材 #$id（素材库里已找不到）'),
              });
          continue;
        }
        await _store(material, null);
      } catch (e) {
        _saving.remove(id);
        AppLog.warn('补取已选素材 $id 失败：$e');
      }
      if (!mounted) return;
    }
  }

  /// 方案里引用到的全部候选 id（两层都算）
  Set<int> _referencedCandidateIds() => {
        for (final r in _picking.replacements) ...[
          ...r.wholeCandidateIds,
          for (final ids in r.shotCandidateIds.values) ...ids,
        ],
      };

  void _emitPicked() {
    final list = _picked.values.toList(growable: false);
    widget.onPickedMaterialsChanged?.call(List.unmodifiable(list));
  }

  /// 当前作用域的托盘内容。顺序按用户勾选的先后，不按 id
  List<PickedItem> get _pickedItems {
    final ids = switch (_picking.currentMode) {
      ReplacementMode.keepOriginal => const <int>[],
      ReplacementMode.whole => _picking.currentReplacement.wholeCandidateIds,
      ReplacementMode.perShot =>
        _picking.currentReplacement.shotCandidateIds[
                _picking.selectedShotIndex ?? -1] ??
            const <int>[],
    };
    final preview = _picking.previewCandidateId;
    return [
      for (final id in ids)
        PickedItem(
          candidateId: id,
          material: _picked[id],
          isPreview: id == preview,
          targetMs: _scope.targetDurationMs,
          media: widget.mediaCache?.statusOf(id) ?? PickedMediaStatus.ready,
          mediaFailure: widget.mediaCache?.failureOf(id),
        ),
    ];
  }

  /// 方案/选中变化后按需重新检索（同一作用域不重复打网络），并把改动落库。
  void _onPickingChanged() {
    if (!mounted) return;
    // 勾一条候选就是一次改动，直接落库：工作台里没有「未保存」这回事。
    // markSaved 会再 notify 一次，但那一次 dirty 已是 false，不会递归。
    if (_picking.dirty && !widget.readOnly) _emit();
    unawaited(_syncPicked());
    final before = _searchMode;
    _syncSearchMode();
    if (before != _searchMode) setState(() {});
    unawaited(_refreshSearchIfNeeded());
  }

  /// 标签不可用时自动落到画面描述——把一个用不了的检索方式选中着，面板就
  /// 永远是空的。规则与「什么时候切回来」见 [nextSearchMode]
  void _syncSearchMode() {
    final scope = _scope;
    final next = nextSearchMode(
      current: _searchMode,
      tagAvailable: scope.tagUnavailableText == null,
      tagPending: scope.tagPending,
      descriptionSupported: scope.descriptionSupported,
      userPinned: _modeUserPinned,
      autoFellBack: _modeAutoFellBack,
    );
    _searchMode = next.mode;
    _modeAutoFellBack = next.autoFellBack;
  }

  PickingScope get _scope => PickingScope.from(
        picking: _picking,
        resolver: _tagResolver,
        shotTagGroups: widget.shotTagGroups,
        unitTagGroups: widget.unitTagGroups,
      );

  Future<void> _refreshSearchIfNeeded() async {
    if (_picking.currentMode == ReplacementMode.keepOriginal) {
      _lastSearchKey = null;
      _search.clear();
      return;
    }
    // 项目进指纹：换了项目就得重搜，同一个标签在别的项目下命中的是另一批素材。
    //
    // 解析出来的标签 id 也进指纹：标签表是异步拉的，第一次进来时它还没到手，
    // 这一刻算出的检索键是空的。拉完之后 id 从空变成一串，指纹跟着变，这次
    // 检索才会真的重跑——此前指纹里没有它，拉完就直接 return 了，面板一直
    // 停在「无法检索」，只能退出任务再进来。
    final key = '${_picking.selectedUnitIndex}/${_picking.selectedShotIndex}/'
        '${_searchMode.name}/${_picking.currentMode.name}/'
        '${widget.project?.id ?? 0}/${_scope.tagIds.join(',')}';
    if (key == _lastSearchKey) return;
    _lastSearchKey = key;
    await _runSearch();
  }

  /// 收紧检索标签：把没有区分度的剔出去（见 [narrowTagQuery]）。
  ///
  /// 必须做，否则真机上会出现「51 个镜头搜出来的东西一模一样」——它们全带
  /// 「实拍」，而「实拍」单独就命中该项目的全部 5437 条，「满足其一」的并集
  /// 永远被它撑满。
  ///
  /// 各标签的条数走 [TagHitProbe]（按项目+标签缓存），且**并发数**：同一批
  /// 标签在几十个镜头之间反复出现，第一次之后就是命中缓存，几乎不花时间。
  Future<TagQueryPlan> _narrowedTags(PickingScope scope) async {
    final tags = <({String name, int id})>[
      for (var i = 0; i < scope.tagNames.length; i++)
        if (i < scope.tagIds.length)
          (name: scope.tagNames[i], id: scope.tagIds[i]),
    ];
    if (tags.length < 2) {
      return TagQueryPlan(tagIds: scope.tagIds);
    }
    try {
      final hits =
          await _tagHitProbe.probe(tags: tags, projectIds: _projectIds);
      // 分母：判断一个标签宽不宽，要看它占本项目的多少，不能拿标签之间互相比
      final total = await _tagHitProbe.libraryTotal(projectIds: _projectIds);
      final narrowed = narrowTagQuery(hits: hits, libraryTotal: total);
      // 收紧之后一个标签都不剩（比如一条条数都没数出来）就退回原样。
      // 空检索键换来的是 CLI 那句「未选择任何标签」的红字，比搜得宽糟得多
      if (narrowed.tagIds.isEmpty) return TagQueryPlan(tagIds: scope.tagIds);
      return narrowed;
    } catch (e) {
      AppLog.warn('收紧检索标签失败，按原样检索：$e');
      return TagQueryPlan(tagIds: scope.tagIds);
    }
  }

  /// 就地重新拉标签表。
  ///
  /// 拉失败后原来没有任何重试路径，只能退出任务再进来——面板上那句
  /// 「暂时不能按标签检索」就一直挂着
  Future<void> _retryTagVocabulary() async {
    _tagResolver.reset();
    setState(() {});
    await _loadTagVocabulary();
  }

  /// 逐个标签数一遍。每个标签一次子进程，所以只在用户主动点了才跑。
  Future<void> _probeTagHits() async {
    final scope = _scope;
    final tags = <({String name, int id})>[
      for (final name in scope.tagNames)
        if (_tagResolver.idsOf([name]).firstOrNull case final id?)
          (name: name, id: id),
    ];
    if (tags.isEmpty) return;
    setState(() => _tagHitsLoading = true);
    try {
      final hits =
          await _tagHitProbe.probe(tags: tags, projectIds: _projectIds);
      if (mounted) setState(() => _tagHits = hits);
    } finally {
      if (mounted) setState(() => _tagHitsLoading = false);
    }
  }

  Future<void> _runSearch() async {
    final scope = _scope;
    // 换了作用域，上一段的标签清单就不作数了
    _tagHits = null;
    switch (_searchMode) {
      case CandidateSearchMode.tag:
        // 一个标签 id 都没解析出来就别去调 CLI。它只会回一句「未选择任何
        // 标签，无法检索候选素材」，用红色错误把整个面板盖住——而真正的
        // 原因（标签表还在拉 / 这一层的标签不在当前标签组里）已经写在
        // 检索方式下方那行灰字里了，红字反而把它压住。
        if (scope.tagIds.isEmpty) {
          setState(() => _tagPlan = null);
          _search.clear();
          return;
        }
        final plan = await _narrowedTags(scope);
        if (!mounted) return;
        setState(() => _tagPlan = plan);
        await _search.searchByTags(tagIds: plan.tagIds);
      case CandidateSearchMode.description:
        await _search.searchByDescription(scope.descriptionKeyword);
      case CandidateSearchMode.image:
        // 首帧搜图未接通（原片这一帧不在素材库里，没有可用的检索键）
        _search.clear();
    }
  }

  void _onSearchModeChanged(CandidateSearchMode mode) {
    if (mode == _searchMode) return;
    setState(() {
      _searchMode = mode;
      // 用户点过的选择就钉住：之后换镜头也不再自动改
      _modeUserPinned = true;
      _modeAutoFellBack = false;
    });
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
          tagPlan: _tagPlan,
          onRetryTags: _retryTagVocabulary,
          searchMode: _searchMode,
          onSearchModeChanged: _onSearchModeChanged,
          onModeChanged: _onModeChanged,
          view: _view,
          onViewChanged: (v) => setState(() => _view = v),
          onPreview: widget.onPreview ?? showCandidatePreview,
          tagHits: _tagHits,
          tagHitsLoading: _tagHitsLoading,
          onProbeTagHits: _probeTagHits,
          projectName: widget.project?.name,
          picked: _pickedItems,
          onRemovePicked:
              widget.readOnly ? null : _picking.toggleCandidate,
          onSetPreviewPicked:
              widget.readOnly ? null : _picking.setPreviewCandidate,
          onRetryPickedMedia: widget.mediaCache == null || widget.readOnly
              ? null
              : widget.mediaCache!.retry,
          pickedMediaTracked: widget.mediaCache != null,
          compactCards: _compactCards,
          onCompactCardsChanged: (v) => setState(() => _compactCards = v),
        ),
      );
}
