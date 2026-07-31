import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/models/shot.dart';
import '../../core/replacement/replacement_plan.dart';
import 'candidate_card.dart';
import 'candidate_search_controller.dart';
import 'picking_controller.dart';
import 'picking_messages.dart';
import 'picking_scope.dart';
import 'picking_widgets.dart';

/// 阶段②右栏：替换模式三态分段 → 视觉镜头条 → 检索方式 → 候选卡 → 因子小结。
///
/// 本组件只负责**呈现与转发意图**：方案改动交给 [PickingController]，
/// 检索交给 [CandidateSearchController]，检索键的推导交给 [PickingScope]。
class CandidatePanel extends StatelessWidget {
  final PickingController picking;
  final CandidateSearchController search;
  final PickingScope scope;

  /// 当前检索方式（三选一互斥）
  final CandidateSearchMode searchMode;
  final ValueChanged<CandidateSearchMode> onSearchModeChanged;

  /// 切模式会丢弃已选候选时由页面弹二次确认，因此这里只上抛意图
  final ValueChanged<ReplacementMode> onModeChanged;

  const CandidatePanel({
    super.key,
    required this.picking,
    required this.search,
    required this.scope,
    required this.searchMode,
    required this.onSearchModeChanged,
    required this.onModeChanged,
  });

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
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
            child: _searchSegment(),
          ),
          Expanded(child: _body()),
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
        ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PickingSegmented(
          selectedIndex: CandidateSearchMode.values.indexOf(searchMode),
          options: [
            SegmentOption(
              key: const Key('picking-search-tag'),
              label: '标签',
              enabled: tagReason == null,
              onTap: () => onSearchModeChanged(CandidateSearchMode.tag),
            ),
            SegmentOption(
              key: const Key('picking-search-description'),
              label: '画面描述',
              onTap: () => onSearchModeChanged(CandidateSearchMode.description),
            ),
            SegmentOption(
              key: const Key('picking-search-image'),
              label: '首帧搜图',
              enabled: false,
              onTap: () => onSearchModeChanged(CandidateSearchMode.image),
            ),
          ],
        ),
        if (tagReason != null) _reasonText(tagReason),
        if (searchMode == CandidateSearchMode.image)
          _reasonText(imageSearchUnavailableReason),
      ],
    );
  }

  Widget _reasonText(String text) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Text(text,
            style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: AppFontSize.micro,
                height: 1.5)),
      );

  /// 候选区：五种状态各有明确呈现，任何一种都不留空白
  Widget _body() {
    if (picking.currentMode == ReplacementMode.keepOriginal) {
      return _hint('这个台词语义单元保留原片。要替换的话，先在上方选择「整体替换」或「镜头替换」');
    }
    switch (search.status) {
      case CandidateSearchStatus.idle:
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
          return _hint(emptyResultGuidance(
              mode: searchMode, queryTagCount: scope.tagIds.length));
        }
        return _grid();
    }
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

  Widget _grid() {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
        childAspectRatio: 9 / 13.5,
      ),
      itemCount: search.entries.length,
      itemBuilder: (context, i) {
        final entry = search.entries[i];
        return CandidateCard(
          entry: entry,
          selected: picking.isCandidateSelected(entry.material.id),
          targetMs: scope.targetDurationMs,
          onTap: () => picking.toggleCandidate(entry.material.id),
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
      child: Text(
        selectionSummaryText(
          unitIndex: picking.selectedUnitIndex,
          shotIndex: picking.selectedShotIndex,
          selectedCount: picking.selectedCountInScope,
          totalCount: search.total,
          replacement: picking.currentReplacement,
          shotCount: picking.currentShotCount,
        ),
        style: const TextStyle(
            color: AppColors.textSecondary, fontSize: AppFontSize.caption),
      ),
    );
  }
}
