import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_failure.dart';
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

  /// 检索失败后原样重发。为空则失败提示不带「重试」按钮
  final VoidCallback? onRetrySearch;

  /// 打开 miaoa 登录（检索因登录失效而失败时的对症动作）。
  /// 为空则退回普通「重试」——但正常接线时不该为空：让用户对着一句
  /// 「请去重新登录」自己找路，等于没给动作
  final VoidCallback? onRelogin;

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

  /// 取消勾选 / 设为预览版 / 重新下载素材本体
  final ValueChanged<int>? onRemovePicked;
  final ValueChanged<int>? onSetPreviewPicked;
  final ValueChanged<int>? onRetryPickedMedia;

  /// 这台机器上做不做素材本地固定（决定托盘上说不说「已存到本地」）
  final bool pickedMediaTracked;

  /// 候选卡是大图还是小图。挑素材有两种节奏——「扫一眼过一批」要小图，
  /// 「看清这条到底行不行」要大图，不该替用户做单选题
  final bool compactCards;
  final ValueChanged<bool>? onCompactCardsChanged;

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
    this.onRetrySearch,
    this.onRelogin,
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
    this.onRetryPickedMedia,
    this.pickedMediaTracked = false,
    this.compactCards = true,
    this.onCompactCardsChanged,
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
      // **候选区是主体，其余都是辅助。** 此前 tab 到卡片之间挤了七行
      // （标题、模式、锁定说明、排除说明、镜头条、检索方式、托盘说明+托盘），
      // 候选卡只剩最下面被切掉一半的一条——用户原话：「我连一个视频的完整的
      // 预览图我都看不到，你就别说更去选择了。」
      //
      // 重排的原则：**要看到完整的一行，而不是更多张半截的**。常驻的只留
      // 「必须一眼看见」的（作用域、模式、镜头、检索方式），其余全部收成
      // 一个可展开的说明条。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(),
          if (picking.currentMode == ReplacementMode.perShot) _shotStrip(),
          _notesBar(),
          Expanded(child: _body(context)),
          _footer(),
        ],
      ),
    );
  }

  /// 一行工具条：作用域 + 替换模式 + 检索方式 + 项目组。
  ///
  /// 这四样是**每一刻都要能看见、能改**的，所以常驻；但它们此前各占一行，
  /// 加起来吃掉右栏近一半的高度。并成一行之后候选区多出两行卡片的位置。
  Widget _toolbar() {
    final unit = picking.currentUnit;
    final seconds = unit == null ? 0.0 : unit.durationMs / 1000;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
      child: Row(
        children: [
          Text(
            'U${picking.selectedUnitIndex + 1}',
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: AppFontSize.emphasis,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 4),
          Text('${seconds.toStringAsFixed(1)}s',
              style: const TextStyle(
                  color: AppColors.textTertiary, fontSize: AppFontSize.micro)),
          const SizedBox(width: AppSpacing.md),
          Expanded(flex: 4, child: _modeSegment()),
          if (_hasSearchSegment) ...[
            const SizedBox(width: AppSpacing.sm),
            Expanded(flex: 3, child: _searchSegment()),
          ],
          if (_canSwitchView) ...[
            const SizedBox(width: AppSpacing.sm),
            Expanded(flex: 2, child: _viewSegment()),
          ],
          const SizedBox(width: AppSpacing.sm),
          _densityToggle(),
          const SizedBox(width: AppSpacing.xs),
          // 面板窄的时候项目名可能很长，让它省略而不是把别的挤出去
          Flexible(flex: 2, child: _projectChip()),
        ],
      ),
    );
  }

  /// 大图 / 小图。一屏八张看得清 vs 一屏二十几张扫得快，各有各的用处
  Widget _densityToggle() => Tooltip(
        message: compactCards ? '换成大图（看得清）' : '换成小图（一屏看得多）',
        child: InkWell(
          key: const Key('picking-card-density'),
          onTap: () => onCompactCardsChanged?.call(!compactCards),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(
              compactCards ? Icons.photo_size_select_large : Icons.grid_view,
              size: 15,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      );

  /// 说明条：模式锁定的原因、被排除的标签、已选状态。
  ///
  /// 这些都是**看一眼就够、不需要一直摊在眼前**的信息，所以收成一行；
  /// 想看全文就点开。此前它们各占一行常驻，纯粹在和候选区抢地方。
  Widget _notesBar() {
    final notes = _noteTexts();
    if (notes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
      child: Tooltip(
        message: notes.join('\n'),
        child: Row(
          children: [
            const Icon(Icons.info_outline,
                size: 11, color: AppColors.textTertiary),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                notes.join(' · '),
                key: const Key('picking-notes'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: AppFontSize.micro),
              ),
            ),
            // 标签表拉失败时的**就地重试**出口。此前没有任何路径会再拉一次，
            // 只能退出任务重进（用户原话：「那为什么不直接加个刷新按钮」）
            if (scope.tagUnavailableText != null && onRetryTags != null)
              GestureDetector(
                key: const Key('picking-retry-tags'),
                onTap: onRetryTags,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.only(left: AppSpacing.sm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh, size: 11, color: AppColors.accentBlue),
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

  /// 这一刻有哪些话要说。灰掉一个按钮却不说为什么，用户只会反复点它——
  /// 但也不必让每句话各占一行常驻。
  List<String> _noteTexts() {
    final notes = <String>[];
    if (picking.wholeLocked || picking.perShotLocked) {
      notes.add(picking.wholeLocked
          ? '已进入镜头替换，整体替换被锁定。清空本单元的镜头选择后可切回'
          : '已进入整体替换，镜头替换被锁定。清空本单元的整体选择后可切回');
    }
    if (!picking.canUsePerShot) {
      notes.add('这个台词语义单元没有切出视觉镜头，只能整体替换或保留原片');
    }
    final plan = tagPlan;
    if (searchMode == CandidateSearchMode.tag && plan != null) {
      final reasons = <String>[
        if (plan.droppedEmpty.isNotEmpty)
          '${plan.droppedEmpty.join('、')}（本项目下没有素材）',
        if (plan.droppedBroad.isNotEmpty)
          '${plan.droppedBroad.join('、')}（几乎命中全部素材，用了等于没筛）',
      ];
      if (reasons.isNotEmpty) notes.add('已排除 ${reasons.join('；')}');
    }
    if (scope.tagUnavailableText case final reason?) notes.add(reason);
    if (searchMode == CandidateSearchMode.image) {
      notes.add(imageSearchUnavailableReason);
    }
    return notes;
  }

  /// 视觉镜头条：S1/S2/S3…各带自己的候选数（未选的显示「原片」）
  Widget _shotStrip() {
    final shots = picking.currentUnit?.shots ?? const <Shot>[];
    return SizedBox(
      // 34 而不是 44：镜头条是必须常驻的（它是这一层的主操作），
      // 但每高 10pt 就少看一截预览图
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('S${i + 1}',
                      style: TextStyle(
                          color: selected
                              ? AppColors.purple
                              : AppColors.textSecondary,
                          fontSize: AppFontSize.caption,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(width: 4),
                  // 「原片 / ×2」横着放在编号旁边——竖着摞会让这一条高一倍
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
  /// 检索方式三选一（互斥）。**只画控件**——不可用的原因收进说明条：
  /// 让说明跟着控件走，它在窄槽里会折成十几行，把整个面板撑破（真机上
  /// 320 宽的窗口溢出了 244px）
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
    if (modes.length <= 1) return const SizedBox.shrink();
    return PickingSegmented(
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
                onTap: () => onSearchModeChanged(CandidateSearchMode.image),
              ),
          },
      ],
    );
  }



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
        return _searchFailure();
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

  /// 检索失败：文案 + 对症的动作按钮，绝不让用户对着一句红字无路可走。
  /// 登录失效给「重新登录」（一键拉起登录页），其余失败给「重试」
  Widget _searchFailure() {
    final needsLogin = search.failureKind == MiaoaFailureKind.unauthorized;
    final action = needsLogin && onRelogin != null
        ? FilledButton.tonal(
            key: const ValueKey('candidate-relogin'),
            onPressed: onRelogin,
            child: const Text('重新登录'))
        : onRetrySearch != null
            ? OutlinedButton(
                key: const ValueKey('candidate-retry-search'),
                onPressed: onRetrySearch,
                child: const Text('重试'))
            : null;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Align(
        alignment: Alignment.topCenter,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          PickingHint(
              text: search.failureMessage ?? '素材库检索失败，请稍后重试',
              color: AppColors.red,
              icon: Icons.error_outline),
          if (action != null) ...[
            const SizedBox(height: AppSpacing.sm),
            action,
          ],
        ]),
      ),
    );
  }

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
        onRetryMedia: onRetryPickedMedia,
        mediaTracked: pickedMediaTracked,
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
            onTap: () => _toggleWithNotice(context, picking, entry.material.id),
            onPlay: () => onPreview(context, entry.material),
            queryTags: scope.tagNames,
            isPreview: picking.previewCandidateId == entry.material.id,
            onSetPreview: picked
                ? () => picking.setPreviewCandidate(entry.material.id)
                : null,
          );
        },
      );

  /// 画面视图：**先保证一行完整**，再考虑放几行。
  ///
  /// 用户原话：「我连一个视频的完整的预览图我都看不到，你就别说更去选择了。」
  /// ——他要的是完整，不是更多张半截的。所以卡片高度按可用高度算：放得下
  /// 两行就用小卡片，放不下就用一行大的，绝不留半截。
  Widget _grid(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      // 一行完整需要多高：卡片本身 + 上下间距
      const gap = AppSpacing.sm;
      final minHeight = compactCards ? _compactMinHeight : _largeMinHeight;
      final rows =
          ((box.maxHeight + gap) / (minHeight + gap)).floor().clamp(1, 3);
      final cardHeight =
          ((box.maxHeight - gap * (rows - 1)) / rows).clamp(minHeight, 320.0);
      return _gridWith(context, cardHeight);
    });
  }

  /// 小图：一张至少这么高（9:16 竖屏，对应约 68 宽）。定在 120 是为了让常见的
  /// 右栏高度**恰好排得下两行**——一屏能扫到二十几张，又每一张都是完整的
  static const double _compactMinHeight = 120;

  /// 大图：一屏只放得下一行，但画面细节看得清
  static const double _largeMinHeight = 200;

  Widget _gridWith(BuildContext context, double cardHeight) {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        // 卡片按 9:16 竖屏配宽，画面才不会被压扁
        maxCrossAxisExtent: cardHeight * 9 / 16 + 6,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
        mainAxisExtent: cardHeight,
      ),
      itemCount: search.entries.length,
      itemBuilder: (context, i) {
        final entry = search.entries[i];
        final picked = picking.isCandidateSelected(entry.material.id);
        return CandidateCard(
          entry: entry,
          selected: picked,
          targetMs: scope.targetDurationMs,
          onTap: () => _toggleWithNotice(context, picking, entry.material.id),
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


/// 勾选并处理「被拦下」：素材已用在别的位置时，控制器不落选择、只留一条
/// 原因——这里把它弹出来。不弹的话用户点了没反应，只会以为软件坏了
void _toggleWithNotice(
    BuildContext context, PickingController picking, int candidateId) {
  picking.toggleCandidate(candidateId);
  final message = picking.takeBlockedMessage();
  if (message == null) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
