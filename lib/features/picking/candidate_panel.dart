import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/models/shot.dart';
import '../../core/replacement/replacement_plan.dart';
import 'candidate_card.dart';
import 'candidate_preview.dart';
import 'candidate_row.dart';
import 'candidate_search_controller.dart';
import 'tag_hit_probe.dart';
import 'picking_controller.dart';
import 'picking_messages.dart';
import 'picking_scope.dart';
import 'tag_query_narrowing.dart';
import 'picked_tray.dart';
import 'picking_widgets.dart';

/// 阶段②右栏：替换模式三态分段 → 视觉镜头条 → 检索方式 → 候选卡 → 因子小结。
///
/// 本组件只负责**呈现与转发意图**：方案改动交给 [PickingController]，
/// 检索交给 [CandidateSearchController]，检索键的推导交给 [PickingScope]。
class CandidatePanel extends StatelessWidget {
  final PickingController picking;
  final CandidateSearchController search;
  final PickingScope scope;

  /// 这一次实际用了哪几个标签、剔掉了哪几个（见 [narrowTagQuery]）。
  /// 不说清楚的话，用户看到结果变了却不知道为什么
  final TagQueryPlan? tagPlan;

  /// 重新拉标签表并重跑检索。为空表示上层没接（测试里常见）
  final VoidCallback? onRetryTags;

  /// 当前检索方式（三选一互斥）
  final CandidateSearchMode searchMode;
  final ValueChanged<CandidateSearchMode> onSearchModeChanged;

  /// 切模式会丢弃已选候选时由页面弹二次确认，因此这里只上抛意图
  final ValueChanged<ReplacementMode> onModeChanged;

  /// 台词视图 / 画面视图。整体替换默认台词——那一层换的是「一句话对应的一段
  /// 画面」，先要看的是这条素材原本在说什么。
  final CandidateView view;
  final ValueChanged<CandidateView> onViewChanged;

  /// 试看一条素材。注入而不是内建：真实实现要构造 mpv 播放器，单测不能碰。
  final CandidatePreviewOpener onPreview;

  /// 逐个标签的命中数（空结果时才有意义）；null 表示还没数过
  final List<TagHit>? tagHits;
  final bool tagHitsLoading;
  final VoidCallback? onProbeTagHits;

  /// 当前作用域已经勾了哪几条（落地记录）。摆在候选区最上面，
  /// 和当前这一页的检索结果是什么完全无关——见 [PickedTray]
  final List<PickedItem> picked;

  /// 取消勾选 / 设为预览版
  final ValueChanged<int>? onRemovePicked;
  final ValueChanged<int>? onSetPreviewPicked;

  /// 检索限定在哪个项目组内；null 表示没设，检索会横跨我的全部项目。
  ///
  /// 必须一直摆在明面上：项目组是排他性的筛选条件，看不见它就没法判断
  /// 「搜出来的东西不对」到底是标签选错了还是根本没限项目。
  final String? projectName;

  const CandidatePanel({
    super.key,
    required this.picking,
    required this.search,
    required this.scope,
    this.tagPlan,
    this.onRetryTags,
    required this.searchMode,
    required this.onSearchModeChanged,
    required this.onModeChanged,
    this.view = CandidateView.transcript,
    required this.onViewChanged,
    this.onPreview = showCandidatePreview,
    this.tagHits,
    this.tagHitsLoading = false,
    this.onProbeTagHits,
    this.projectName,
    this.picked = const [],
    this.onRemovePicked,
    this.onSetPreviewPicked,
  });

  /// 镜头替换只有画面视图：那一层挑的就是画面，摆一个台词列表反而绕远
  bool get _canSwitchView =>
      picking.currentMode == ReplacementMode.whole;

  CandidateView get _effectiveView =>
      _canSwitchView ? view : CandidateView.gallery;

  /// 检索方式那一栏有没有东西可画。整体替换只有「标签」一条路（见
  /// [_searchSegment]），既没有分段按钮也没有原因说明时它是空的
  bool get _hasSearchSegment =>
      scope.descriptionSupported ||
      scope.tagUnavailableText != null ||
      searchMode == CandidateSearchMode.image;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceRaised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
            child: _modeSegment(),
          ),
          ..._modeNotes(),
          if (picking.currentMode == ReplacementMode.perShot) _shotStrip(),
          // 检索方式与「台词/画面」并排放一行。右栏宽 1200 而高只有 400 出头，
          // 两条通栏分段各占一行等于白扔掉一排素材的位置
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_hasSearchSegment) Expanded(flex: 3, child: _searchSegment()),
                if (_canSwitchView) ...[
                  if (_hasSearchSegment) const SizedBox(width: AppSpacing.md),
                  // 检索方式那半边空着时就整行都归它，不留一块没用的空地
                  Expanded(flex: _hasSearchSegment ? 2 : 5, child: _viewSegment()),
                ],
              ],
            ),
          ),
          Expanded(child: _body(context)),
          _footer(),
        ],
      ),
    );
  }

  Widget _header() {
    final unit = picking.currentUnit;
    final seconds = unit == null ? 0.0 : unit.durationMs / 1000;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
      child: Row(
        children: [
          Text(
            'U${picking.selectedUnitIndex + 1} · 候选素材',
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: AppFontSize.emphasis,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text('${seconds.toStringAsFixed(1)}s',
              style: const TextStyle(
                  color: AppColors.textTertiary, fontSize: AppFontSize.caption)),
          const Spacer(),
          // 面板窄的时候项目名可能很长，让它省略而不是把标题挤出去
          Flexible(child: _projectChip()),
        ],
      ),
    );
  }

  /// 项目组范围。设了就低调显示，没设就用警示色——不限项目时搜出来的
  /// 素材横跨几十个项目，多半用不上，这个状态必须刺眼
  Widget _projectChip() {
    final name = projectName;
    final scoped = name != null && name.isNotEmpty;
    final color = scoped ? AppColors.textSecondary : AppColors.orange;
    return Container(
      key: const Key('picking-project-scope'),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        scoped ? '限定项目组 · $name' : '未设项目组 · 搜的是我的全部项目',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: AppFontSize.caption),
      ),
    );
  }

  /// 三态互斥：进入一方另一方锁定（[PickingController] 已算好锁定态）
  Widget _modeSegment() {
    final mode = picking.currentMode;
    return PickingSegmented(
      activeColor: ReplacementBadge.colorOf(picking.currentReplacement),
      selectedIndex: ReplacementMode.values.indexOf(mode),
      options: [
        SegmentOption(
          key: const Key('picking-mode-keep'),
          label: '保留原片',
          onTap: () => onModeChanged(ReplacementMode.keepOriginal),
        ),
        SegmentOption(
          key: const Key('picking-mode-whole'),
          label: '整体替换',
          enabled: !picking.wholeLocked,
          locked: picking.wholeLocked,
          onTap: () => onModeChanged(ReplacementMode.whole),
        ),
        SegmentOption(
          key: const Key('picking-mode-per-shot'),
          label: '镜头替换',
          enabled: picking.canUsePerShot && !picking.perShotLocked,
          locked: picking.perShotLocked,
          onTap: () => onModeChanged(ReplacementMode.perShot),
        ),
      ],
    );
  }

  /// 模式分段下方的说明：锁定原因、没有视觉镜头的原因。
  /// 灰掉一个按钮却不说为什么，用户只会反复点它。
  List<Widget> _modeNotes() {
    final notes = <Widget>[];
    if (picking.wholeLocked || picking.perShotLocked) {
      notes.add(_note(
        const Key('picking-mode-lock-hint'),
        picking.wholeLocked
            ? '已进入镜头替换，整体替换被锁定。清空本单元的镜头选择后可切回'
            : '已进入整体替换，镜头替换被锁定。清空本单元的整体选择后可切回',
      ));
    }
    if (!picking.canUsePerShot) {
      notes.add(_note(
        const Key('picking-no-shot-hint'),
        '这个台词语义单元没有切出视觉镜头，只能整体替换或保留原片',
      ));
    }
    final plan = tagPlan;
    if (searchMode == CandidateSearchMode.tag && plan != null) {
      final reasons = <String>[
        if (plan.droppedEmpty.isNotEmpty)
          '${plan.droppedEmpty.join('、')}（本项目下没有素材）',
        if (plan.droppedBroad.isNotEmpty)
          '${plan.droppedBroad.join('、')}（几乎命中全部素材，用了等于没筛）',
      ];
      if (reasons.isNotEmpty) {
        notes.add(_note(
          const Key('picking-tag-narrowed'),
          '已排除 ${reasons.join('；')}',
        ));
      }
    }
    return notes;
  }

  Widget _note(Key key, String text) => Padding(
        key: key,
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
        child: Text(text,
            style: const TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.micro)),
      );

  /// 视觉镜头条：S1/S2/S3…各带自己的候选数（未选的显示「原片」）
  Widget _shotStrip() {
    final shots = picking.currentUnit?.shots ?? const <Shot>[];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
        itemCount: shots.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, i) {
          final picked =
              picking.currentReplacement.shotCandidateIds[i] ?? const <int>[];
          final selected = picking.selectedShotIndex == i;
          return GestureDetector(
            key: Key('picking-shot-$i'),
            behavior: HitTestBehavior.opaque,
            onTap: () => picking.selectShot(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.purple.withValues(alpha: 0.16)
                    : AppColors.surfaceCard,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                    color: selected ? AppColors.purple : Colors.transparent),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('S${i + 1}',
                      style: TextStyle(
                          color: selected
                              ? AppColors.purple
                              : AppColors.textSecondary,
                          fontSize: AppFontSize.caption,
                          fontWeight: FontWeight.w700)),
                  Text(
                    picked.isEmpty ? '原片' : '×${picked.length}',
                    style: TextStyle(
                        color: picked.isEmpty
                            ? AppColors.orange
                            : AppColors.green,
                        fontSize: AppFontSize.micro),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 检索方式三选一（互斥）。不可用的方式点不动，原因写在下方而不是留白。
  Widget _searchSegment() {
    final tagReason = scope.tagUnavailableText;
    // 整体替换只有「标签」一条路，就别摆一排按钮：画面描述是按镜头生成的，
    // 首帧搜图还没接通——三选一里两个点不动，看着像是坏了
    final modes = <CandidateSearchMode>[
      CandidateSearchMode.tag,
      if (scope.descriptionSupported) ...[
        CandidateSearchMode.description,
        CandidateSearchMode.image,
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (modes.length > 1)
          PickingSegmented(
            selectedIndex: modes.indexOf(searchMode).clamp(0, modes.length - 1),
            options: [
              for (final mode in modes)
                switch (mode) {
                  CandidateSearchMode.tag => SegmentOption(
                      key: const Key('picking-search-tag'),
                      label: '标签',
                      enabled: tagReason == null,
                      onTap: () => onSearchModeChanged(CandidateSearchMode.tag),
                    ),
                  CandidateSearchMode.description => SegmentOption(
                      key: const Key('picking-search-description'),
                      label: '画面描述',
                      onTap: () =>
                          onSearchModeChanged(CandidateSearchMode.description),
                    ),
                  CandidateSearchMode.image => SegmentOption(
                      key: const Key('picking-search-image'),
                      label: '首帧搜图',
                      enabled: false,
                      onTap: () =>
                          onSearchModeChanged(CandidateSearchMode.image),
                    ),
                },
            ],
          ),
        if (tagReason != null) _tagUnavailable(tagReason),
        if (searchMode == CandidateSearchMode.image)
          _reasonText(imageSearchUnavailableReason),
      ],
    );
  }

  /// 标签检索用不了时，除了写清原因还要给一个**就地重试**的出口。
  ///
  /// 此前标签表拉失败后没有任何路径会再拉一次——只能退出去重进任务才恢复。
  /// 用户的原话：「如果我每次刷新回来它就有的话，那为什么不直接加个刷新按钮」
  Widget _tagUnavailable(String reason) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(reason,
                  style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.micro,
                      height: 1.5)),
            ),
            if (onRetryTags != null)
              GestureDetector(
                key: const Key('picking-retry-tags'),
                onTap: onRetryTags,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.only(left: AppSpacing.sm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh,
                          size: 12, color: AppColors.accentBlue),
                      SizedBox(width: 2),
                      Text('重试',
                          style: TextStyle(
                              color: AppColors.accentBlue,
                              fontSize: AppFontSize.micro)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _reasonText(String text) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Text(text,
            style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: AppFontSize.micro,
                height: 1.5)),
      );

  /// 台词 / 画面两种看法
  Widget _viewSegment() => PickingSegmented(
        selectedIndex: CandidateView.values.indexOf(_effectiveView),
        options: [
          SegmentOption(
            key: const Key('picking-view-transcript'),
            label: '台词',
            onTap: () => onViewChanged(CandidateView.transcript),
          ),
          SegmentOption(
            key: const Key('picking-view-gallery'),
            label: '画面',
            onTap: () => onViewChanged(CandidateView.gallery),
          ),
        ],
      );

  /// 分页。命中几百条时只给第一页，用户根本不知道后面还有——
  /// 「共 N 条」与页码都要摆出来。
  ///
  /// 和小结共用底栏的一行：右栏的高度全是候选区的本钱，单独占一行等于
  /// 少看一整排素材。
  Widget _pager() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pageButton(
            key: const Key('picking-prev-page'),
            icon: Icons.chevron_left,
            enabled: search.hasPrevPage,
            onTap: search.prevPage,
          ),
          Text(
            '第 ${search.page}/${search.pageCount} 页 · 共 ${search.total} 条',
            style: const TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.micro),
          ),
          _pageButton(
            key: const Key('picking-next-page'),
            icon: Icons.chevron_right,
            enabled: search.hasNextPage,
            onTap: search.nextPage,
          ),
        ],
      );

  Widget _pageButton({
    required Key key,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) =>
      InkWell(
        key: key,
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: 2),
          child: Icon(icon,
              size: 18,
              color:
                  enabled ? AppColors.textSecondary : AppColors.textTertiary),
        ),
      );

  /// 候选区 = 「已选」托盘 + 五种状态之一。
  ///
  /// 托盘在**每一种状态下都在**，包括检索失败和 0 结果——「我选了哪三条」
  /// 和「这次搜到没搜到」是两件事，后者出问题不该把前者也一起吞掉。
  Widget _body(BuildContext context) {
    final content = _content(context);
    if (picked.isEmpty) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: _tray(),
        ),
        Expanded(child: content),
      ],
    );
  }

  Widget _content(BuildContext context) {
    if (picking.currentMode == ReplacementMode.keepOriginal) {
      return _hint('这个台词语义单元保留原片。要替换的话，先在上方选择「整体替换」或「镜头替换」');
    }
    switch (search.status) {
      case CandidateSearchStatus.idle:
        // 标签检索用不了时，原因（表还在拉 / 标签不在当前标签组里）已经写在
        // 检索方式下方那行灰字上，这里再补一句「选择一种检索方式」是废话，
        // 而且会让用户以为还有别的路可选
        if (searchMode == CandidateSearchMode.tag &&
            scope.tagUnavailableText != null) {
          return const SizedBox.shrink();
        }
        return _hint('选择一种检索方式，为这一段挑选候选素材');
      case CandidateSearchStatus.loading:
        return const Center(
            child: SizedBox(
                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
      case CandidateSearchStatus.failed:
        return _hint(search.failureMessage ?? '素材库检索失败，请稍后重试',
            color: AppColors.red, icon: Icons.error_outline);
      case CandidateSearchStatus.ready:
        if (search.entries.isEmpty) {
          return _emptyResult();
        }
        return _effectiveView == CandidateView.transcript
            ? _transcriptList(context)
            : _grid(context);
    }
  }

  /// 空结果不能只说「没有」。用户真正要判断的是「是我标签打错了，还是素材库
  /// 里这一类本来就没入库」——逐个标签数一遍，下一步该做什么才一目了然。
  Widget _emptyResult() {
    final canProbe = searchMode == CandidateSearchMode.tag &&
        scope.tagIds.isNotEmpty &&
        onProbeTagHits != null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PickingHint(
            text: emptyResultGuidance(
                mode: searchMode,
                queryTagCount: scope.tagIds.length,
                perShot: picking.currentMode == ReplacementMode.perShot),
            color: AppColors.textSecondary,
            icon: Icons.info_outline,
          ),
          if (canProbe) ...[
            const SizedBox(height: AppSpacing.md),
            if (tagHits == null)
              OutlinedButton(
                key: const Key('picking-probe-tag-hits'),
                onPressed: tagHitsLoading ? null : onProbeTagHits,
                child: Text(tagHitsLoading ? '正在逐个标签查…' : '逐个标签看看有多少'),
              )
            else
              _tagHitList(),
          ],
        ],
      ),
    );
  }

  Widget _tagHitList() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('这个项目里，每个标签各有多少条素材：',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: AppFontSize.caption)),
          const SizedBox(height: AppSpacing.sm),
          for (final hit in tagHits!)
            Padding(
              key: Key('picking-tag-hit-${hit.tagId}'),
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(hit.name,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: AppFontSize.caption)),
                  Text(
                    hit.count == null ? '查不到' : '${hit.count} 条',
                    style: TextStyle(
                      color: hit.count == null
                          ? AppColors.textTertiary
                          : (hit.count == 0
                              ? AppColors.orange
                              : AppColors.green),
                      fontSize: AppFontSize.caption,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          const Text('0 条的标签说明素材库里这一类还没入库；'
              '都不是 0 却搜不到，是这几个标签没有同时出现在同一条素材上。',
              style: TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: AppFontSize.micro,
                  height: 1.5)),
        ],
      );

  Widget _hint(String text,
          {Color color = AppColors.textSecondary,
          IconData icon = Icons.info_outline}) =>
      Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Align(
          alignment: Alignment.topCenter,
          child: PickingHint(text: text, color: color, icon: icon),
        ),
      );

  /// 一列台词行至少要这么宽，否则缩略图 + 操作按钮挤完就没地方放台词了
  static const double transcriptColumnWidth = 620;

  /// 候选区上方那条「已选」托盘
  Widget _tray() => PickedTray(
        items: picked,
        onRemove: onRemovePicked ?? (_) {},
        onSetPreview: onSetPreviewPicked ?? (_) {},
      );

  /// 台词视图：按可用宽度分列铺开。
  ///
  /// 此前是单列 [ListView]，右栏宽 1200 而高只有 400 出头——一条 88pt 的行
  /// 一屏只放得下两条，右边一半的宽度全空着。改成按宽度分列后同样的位置能
  /// 看到六条，条目顺序仍是逐行从左到右，和素材库返回的顺序一致。
  Widget _transcriptList(BuildContext context) => GridView.builder(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: transcriptColumnWidth,
          crossAxisSpacing: AppSpacing.sm,
          mainAxisSpacing: AppSpacing.sm,
          // 行高由 CandidateRow 定死，不跟着列宽变——用 childAspectRatio 的话
          // 窗口一宽行就跟着变高，白占地方
          mainAxisExtent: CandidateRow.height,
        ),
        itemCount: search.entries.length,
        itemBuilder: (context, i) {
          final entry = search.entries[i];
          final picked = picking.isCandidateSelected(entry.material.id);
          return CandidateRow(
            entry: entry,
            selected: picked,
            targetMs: scope.targetDurationMs,
            onTap: () => picking.toggleCandidate(entry.material.id),
            onPlay: () => onPreview(context, entry.material),
            queryTags: scope.tagNames,
            isPreview: picking.previewCandidateId == entry.material.id,
            onSetPreview: picked
                ? () => picking.setPreviewCandidate(entry.material.id)
                : null,
          );
        },
      );

  /// 画面视图：按可用宽度铺格子。此前写死两列、每格 9:13.5，在右栏那点宽度里
  /// 一屏只能看到两条——挑素材本来就是「扫一眼过一批」的活。
  Widget _grid(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 112,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
        childAspectRatio: 9 / 14,
      ),
      itemCount: search.entries.length,
      itemBuilder: (context, i) {
        final entry = search.entries[i];
        final picked = picking.isCandidateSelected(entry.material.id);
        return CandidateCard(
          entry: entry,
          selected: picked,
          targetMs: scope.targetDurationMs,
          onTap: () => picking.toggleCandidate(entry.material.id),
          onPlay: () => onPreview(context, entry.material),
          queryTags: scope.tagNames,
          isPreview: picking.previewCandidateId == entry.material.id,
          onSetPreview: picked
              ? () => picking.setPreviewCandidate(entry.material.id)
              : null,
        );
      },
    );
  }

  Widget _footer() {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              selectionSummaryText(
                unitIndex: picking.selectedUnitIndex,
                shotIndex: picking.selectedShotIndex,
                selectedCount: picking.selectedCountInScope,
                totalCount: search.total,
                replacement: picking.currentReplacement,
                shotCount: picking.currentShotCount,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: AppFontSize.caption),
            ),
          ),
          if (search.status == CandidateSearchStatus.ready &&
              search.entries.isNotEmpty)
            _pager(),
        ],
      ),
    );
  }
}
