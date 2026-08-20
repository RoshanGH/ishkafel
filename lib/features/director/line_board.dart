import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/voice_catalog.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/shot_allocation.dart';
import '../picking/picked_media_cache.dart';

/// 分镜编辑板（右栏）：**所有行的工作块从上到下铺开**，一块对应一行台词。
///
/// 设计推演见 docs/2026-08-20-编导台行带式布局-设计推演.md——视频是序列，
/// 人从上往下扫一遍就是扫完整条片子；「点一行右边切换」的检查器范式已废。
/// 块内容：台词（只读，编辑在左栏）· 参考段卡 · 镜头序列 · 配音行。
/// 内容切换只发生在**块内**（镜头详情展开/收起）。
class LineBoardHandlers {
  final void Function(int index) onFocusLine;
  final void Function(int index) onFindShots;
  final void Function(int index, int shotIndex) onRemoveShot;
  final void Function(int index, int shotIndex, int newAllocMs) onResizeShot;
  final void Function(int index, int shotIndex, int trimStartMs) onTrimShot;
  final void Function(int index, int shotIndex, double speed) onSpeedShot;
  final void Function(int index) onDistribute;

  /// 素材偏短分不满时：放慢镜头把整行充满
  final void Function(int index) onSlowFill;

  /// 改这一行的标签（从妙啊标签体系里搜索/点选/替换）
  final void Function(int index) onEditTags;

  /// 取段胶片条的素材帧（没抽好返回 null，条退回纯色）
  final List<String>? Function(LineShot shot) shotFramesOf;

  /// 从第 [shotIndex] 镜起分小行（弹台词切点选择器，把这段字指到镜头组）
  final void Function(int index, int shotIndex) onSplitSubline;

  /// 把第 [sublineIndex] 小行并回上一行（删掉那个切点）
  final void Function(int index, int sublineIndex) onMergeSubline;
  final void Function(int index, int? manualMs) onManualMs;
  final void Function(int index) onPickVoice;
  final void Function(int index, int rate) onSpeechRate;
  final void Function(int index) onGenerateVoice;
  final void Function(int index) onTogglePlayVoice;
  final void Function(int index, int segIndex) onPlayReference;
  final void Function(int index, int segIndex) onUseReference;
  final void Function(int index) onUploadReference;

  /// 行级字幕：自定义这一行 / 恢复跟随全局
  final void Function(int index) onEditLineSubtitle;
  final void Function(int index) onClearLineSubtitle;
  final PickedMediaStatus? Function(int materialId) shotStatus;
  final void Function(int materialId) onRetryDownload;

  /// 参考分镜的缩略图本地路径（抽帧后缓存）；null = 还没抽好
  final String? Function(ScriptLine line, int segIndex) refThumbOf;

  const LineBoardHandlers({
    required this.onFocusLine,
    required this.onFindShots,
    required this.onRemoveShot,
    required this.onResizeShot,
    required this.onTrimShot,
    required this.onSpeedShot,
    required this.onDistribute,
    required this.onSlowFill,
    required this.onEditTags,
    required this.shotFramesOf,
    required this.onSplitSubline,
    required this.onMergeSubline,
    required this.onManualMs,
    required this.onPickVoice,
    required this.onSpeechRate,
    required this.onGenerateVoice,
    required this.onTogglePlayVoice,
    required this.onPlayReference,
    required this.onUseReference,
    required this.onUploadReference,
    required this.onEditLineSubtitle,
    required this.onClearLineSubtitle,
    required this.shotStatus,
    required this.onRetryDownload,
    required this.refThumbOf,
  });
}

class LineBoard extends StatelessWidget {
  final ScriptDoc doc;
  final int selected;

  /// 展开镜头详情的位置：(行下标, 镜头下标)；null = 都收着
  final (int, int)? expandedShot;
  final ValueChanged<(int, int)?> onExpandShot;
  final Set<String> generatingLineIds;
  final String? playingLineId;

  /// 预览播放位置当前落在的行：块点亮并自动滚到可见（预览是主角）
  final int? previewLineIndex;
  final LineBoardHandlers handlers;
  final ScrollController? controller;

  const LineBoard({
    super.key,
    required this.doc,
    required this.selected,
    required this.expandedShot,
    required this.onExpandShot,
    required this.generatingLineIds,
    required this.playingLineId,
    this.previewLineIndex,
    required this.handlers,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: doc.lines.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) => _ScrollIntoView(
        key: ValueKey('band-${doc.lines[i].id}'),
        active: i == previewLineIndex,
        child: _LineBand(
          index: i,
          line: doc.lines[i],
          selected: i == selected,
          expandedShot: expandedShot != null && expandedShot!.$1 == i
              ? expandedShot!.$2
              : null,
          onExpandShot: (shot) => onExpandShot(shot == null ? null : (i, shot)),
          generating: generatingLineIds.contains(doc.lines[i].id),
          playing: playingLineId == doc.lines[i].id,
          previewing: i == previewLineIndex,
          handlers: handlers,
        ),
      ),
    );
  }
}

/// 素材取段条（胶片形态）：底条铺**素材的实际帧画面**——拖窗口时
/// 看得见取的是哪段画面，不用猜（用户给的参考图口径）。蓝色窗口 =
/// 这一镜实际用的那一段：**拖窗口整体平移** = 换起点（在素材上滑动
/// 裁切）；**拖右缘把手** = 改时长（多退少补由邻镜配合）。
/// 帧还没抽好时退回纯色条，功能不等待
class _TrimBar extends StatelessWidget {
  final LineShot shot;
  final List<String>? frames;
  final ValueChanged<int> onTrim;
  final ValueChanged<int> onResize;

  const _TrimBar({
    super.key,
    required this.shot,
    required this.frames,
    required this.onTrim,
    required this.onResize,
  });

  @override
  Widget build(BuildContext context) {
    final src = shot.durationMs!;
    final alloc = shot.allocMs ?? 0;
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      // 素材源坐标 → 像素：窗口宽按素材消耗量（变速时窗口 = alloc×speed）
      final pxPerMs = w / src;
      final winLeft = (shot.trimStartMs * pxPerMs).clamp(0.0, w);
      final winWidth =
          (shot.consumedSourceMs * pxPerMs).clamp(8.0, w - winLeft);
      final fs = frames;
      return SizedBox(
        height: 44,
        child: Stack(children: [
          // 底条：素材全长——有帧铺帧（看得见画面），没帧退纯色
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: fs == null || fs.isEmpty
                  ? const ColoredBox(color: AppColors.surfaceCard)
                  : Row(children: [
                      for (final f in fs)
                        Expanded(
                          child: Image.file(File(f),
                              fit: BoxFit.cover,
                              height: double.infinity,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                  color: AppColors.surfaceCard)),
                        ),
                    ]),
            ),
          ),
          // 窗口外的画面压暗：选中的那段自然亮起来
          if (fs != null && fs.isNotEmpty) ...[
            Positioned(
              left: 0,
              width: winLeft,
              top: 0,
              bottom: 0,
              child: const ColoredBox(color: Color(0x99000000)),
            ),
            Positioned(
              left: winLeft + winWidth,
              right: 0,
              top: 0,
              bottom: 0,
              child: const ColoredBox(color: Color(0x99000000)),
            ),
          ],
          // 选段窗口：拖体平移（换起点）
          Positioned(
            left: winLeft,
            width: winWidth,
            top: 0,
            bottom: 0,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => onTrim(
                    (shot.trimStartMs + d.delta.dx / pxPerMs).round()),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // 有帧时窗口只描边不盖色——里面就是选中的画面本身；
                    // 纯色条才需要填充示意
                    color: fs == null || fs.isEmpty
                        ? AppColors.accentBlue.withValues(alpha: 0.28)
                        : Colors.transparent,
                    border: Border.all(color: AppColors.accentBlue, width: 1.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(3)),
                      child: Text('选用 ${_s(alloc)}',
                          style: const TextStyle(
                              fontSize: AppFontSize.micro,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              fontFeatures: [FontFeature.tabularFigures()])),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 右缘把手：拖改时长（素材坐标 → 输出时长除以速度）
          Positioned(
            left: (winLeft + winWidth - 5).clamp(0.0, w - 10),
            width: 10,
            top: 0,
            bottom: 0,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => onResize(
                    (alloc + d.delta.dx / pxPerMs / shot.speed).round()),
                child: Center(
                  child: Container(
                    width: 4,
                    decoration: BoxDecoration(
                        color: AppColors.accentBlueLight,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
              ),
            ),
          ),
        ]),
      );
    });
  }

  /// 取段的数字口径（参考图样式）：左「0.8s ~ 1.5s」（素材内起止）、
  /// 右「素材可用 3.5s」
  Widget rangeCaption() {
    final from = shot.trimStartMs;
    final to = shot.trimStartMs + shot.consumedSourceMs;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(children: [
        Text('${_s(from)} ~ ${_s(to)}',
            style: const TextStyle(
                fontSize: AppFontSize.micro,
                color: AppColors.textSecondary,
                fontFeatures: [FontFeature.tabularFigures()])),
        const Spacer(),
        Text('素材可用 ${_s(shot.durationMs!)}',
            style: const TextStyle(
                fontSize: AppFontSize.micro,
                color: AppColors.textTertiary,
                fontFeatures: [FontFeature.tabularFigures()])),
      ]),
    );
  }

  static String _s(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';
}

/// 悬停时露出遮罩动作（胶片格的播放/用它）：平时画面干净，
/// 指过去操作才出现
class _HoverReveal extends StatefulWidget {
  final Widget Function(bool hovering) builder;

  const _HoverReveal({required this.builder});

  @override
  State<_HoverReveal> createState() => _HoverRevealState();
}

class _HoverRevealState extends State<_HoverReveal> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: widget.builder(_hovering),
      );
}

/// 播放跟到哪一行，就把那一行块滚到可见——人看着自己的片子走，
/// 不用自己追着滚
class _ScrollIntoView extends StatefulWidget {
  final bool active;
  final Widget child;

  const _ScrollIntoView({super.key, required this.active, required this.child});

  @override
  State<_ScrollIntoView> createState() => _ScrollIntoViewState();
}

class _ScrollIntoViewState extends State<_ScrollIntoView> {
  @override
  void didUpdateWidget(_ScrollIntoView old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.active) return;
        Scrollable.ensureVisible(context,
            alignment: 0.25,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic);
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _LineBand extends StatelessWidget {
  final int index;
  final ScriptLine line;
  final bool selected;
  final int? expandedShot;
  final ValueChanged<int?> onExpandShot;
  final bool generating;
  final bool playing;

  /// 预览播放位置正落在这一行
  final bool previewing;
  final LineBoardHandlers handlers;

  const _LineBand({
    required this.index,
    required this.line,
    required this.selected,
    required this.expandedShot,
    required this.onExpandShot,
    required this.generating,
    required this.playing,
    required this.previewing,
    required this.handlers,
  });

  bool get voiced => line.type == ScriptLineType.voiced;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => handlers.onFocusLine(index),
      borderRadius: BorderRadius.circular(AppRadius.md),
      hoverColor: AppColors.hover,
      // 点亮/选中的过渡要有呼吸（180ms）：播放跟随换行时块与块之间
      // 不再闪跳；左缘 3px 播放条是真实元素，不是投影 hack
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: previewing
              ? Color.lerp(
                  AppColors.surfaceRaised, AppColors.accentBlue, 0.06)!
              : AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
              color: selected ? AppColors.accentBlue : AppColors.border,
              width: selected ? 1.2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md + 3, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(),
                  const SizedBox(height: AppSpacing.sm),
                  _shotStrip(),
                  // 镜头详情的展开/收起不许硬切——200ms 缓出
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: (expandedShot != null &&
                            expandedShot! >= 0 &&
                            expandedShot! < line.shots.length)
                        ? Padding(
                            padding: const EdgeInsets.only(top: AppSpacing.sm),
                            child: _shotDetail(
                                expandedShot!, line.shots[expandedShot!]),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (voiced) _voiceRow() else _visualRow(),
                ]),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 3,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: previewing ? 1 : 0,
              child: const ColoredBox(color: AppColors.accentBlue),
            ),
          ),
        ]),
      ),
    );
  }

  // ---- 块头：行号 · 状态点 · 台词（只读，编辑在左栏）----

  Widget _header() {
    final state = line.voiceState;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        margin: const EdgeInsets.only(top: 3),
        width: 20,
        child: Text('${index + 1}',
            style: const TextStyle(
                fontSize: AppFontSize.caption,
                color: AppColors.textTertiary,
                fontFeatures: [FontFeature.tabularFigures()])),
      ),
      Container(
        margin: const EdgeInsets.only(top: 7, right: AppSpacing.sm),
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: !voiced
              ? Colors.transparent
              : switch (state) {
                  LineVoiceState.none => AppColors.textSecondary,
                  LineVoiceState.fresh => AppColors.green,
                  LineVoiceState.stale => AppColors.orange,
                },
          border: Border.all(
              color: voiced ? Colors.transparent : AppColors.textTertiary),
        ),
      ),
      Expanded(
        child: Text(
          voiced ? line.text.trim() : '画面行（无台词，只有画面）',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: AppFontSize.body,
              height: 1.4,
              color: voiced ? AppColors.textPrimary : AppColors.textTertiary),
        ),
      ),
      // 标签可以点开改：从素材库的标签体系里搜索、点选、替换
      Padding(
        padding: const EdgeInsets.only(left: AppSpacing.sm),
        child: InkWell(
          key: ValueKey('band-tags-$index'),
          onTap: () => handlers.onEditTags(index),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
                line.tags.isEmpty ? '＋标签' : line.tags.take(2).join(' · '),
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    color: line.tags.isEmpty
                        ? AppColors.textTertiary.withValues(alpha: 0.7)
                        : AppColors.textTertiary)),
          ),
        ),
      ),
    ]);
  }

  // ---- 左：参考（分子，原文）| 右：我的镜头（译文）——左右对照 ----

  Widget _shotStrip() {
    final root = ShotAllocation.rootMsOf(line);
    final shortfall =
        root == null ? 0 : ShotAllocation.shortfallMs(line.shots, root);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 左：分子级参考卡（与镜头卡同规格），右侧留白比卡间距宽——
        // 原文与译文之间要有一条看得见的呼吸缝（用户定的左右结构）
        SizedBox(height: 132, child: _referenceStrip()),
        const SizedBox(width: AppSpacing.xl),
        Expanded(child: _sublineRows()),
      ]),
      if (line.shots.isNotEmpty && root != null && shortfall != 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            Expanded(
              child: Text(
                  shortfall > 0
                      ? '还有 ${_s(shortfall)} 没分出去（素材可能不够长）'
                      : '超分了 ${_s(-shortfall)}',
                  style: const TextStyle(
                      fontSize: AppFontSize.micro, color: AppColors.orange)),
            ),
            if (shortfall > 0) ...[
              InkWell(
                key: ValueKey('band-slowfill-$index'),
                onTap: () => handlers.onSlowFill(index),
                child: const Text('放慢充满',
                    style: TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.accentBlueLight)),
              ),
              const SizedBox(width: AppSpacing.md),
            ],
            InkWell(
              key: ValueKey('band-distribute-$index'),
              onTap: () => handlers.onDistribute(index),
              child: const Text('重新均分',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.accentBlueLight)),
            ),
          ]),
        ),
    ]);
  }

  /// 参考分镜卡：这一句在参考片里的原始画面，按视觉切点切成多镜
  /// 我的镜头区：按小行分组渲染。没分组 = 一行铺开（现状）；
  /// 分了组 = 每小行「这段台词文字 + 它对应的镜头」——「家人们」
  /// 指定给前两镜，一眼看清哪段字落在哪些镜头上
  Widget _sublineRows() {
    final subs = line.sublines;
    final grouped = subs.length > 1;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var g = 0; g < subs.length; g++) ...[
        if (g > 0) const SizedBox(height: AppSpacing.xs),
        SizedBox(
          height: 132,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (grouped)
              SizedBox(
                width: 76,
                height: 132,
                child: _HoverReveal(
                  builder: (hovering) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('「${subs[g].text.trim()}」',
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: AppFontSize.caption,
                                height: 1.4,
                                color: AppColors.accentBlueLight)),
                        if (hovering && g > 0)
                          InkWell(
                            key: ValueKey('band-merge-subline-$index-$g'),
                            onTap: () => handlers.onMergeSubline(index, g),
                            child: const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Text('并回上行',
                                  style: TextStyle(
                                      fontSize: AppFontSize.micro,
                                      color: AppColors.textTertiary)),
                            ),
                          ),
                      ]),
                ),
              ),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var j = subs[g].shotStart;
                      j < subs[g].shotEnd && j < line.shots.length;
                      j++) ...[
                    _shotCard(j, line.shots[j]),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  if (g == subs.length - 1) _addCard(),
                ],
              ),
            ),
          ]),
        ),
      ],
    ]);
  }

  /// 左侧参考卡：块级只保留**分子粒度**——这一句在原片里的完整片段，
  /// 与镜头卡同规格竖屏摆放（原文｜译文左右对照），点击播放。
  /// 原子（参考分镜）不在这里铺开：它们的主战场在找镜头面板——
  /// 点选哪个原子，就用哪个原子的台词/标签当检索条件
  Widget _referenceStrip() {
    final ref = line.reference;
    if (ref == null) {
      // 没参考：同规格的虚位入口，手写的行也能挂原片对照
      return InkWell(
        key: ValueKey('band-upload-ref-$index'),
        onTap: () => handlers.onUploadReference(index),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        hoverColor: AppColors.hover,
        child: Container(
          width: 74,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
                color: AppColors.textTertiary.withValues(alpha: 0.3)),
          ),
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.video_call_outlined,
                    size: 15,
                    color: AppColors.textTertiary.withValues(alpha: 0.8)),
                const SizedBox(height: 4),
                Text('传参考',
                    style: TextStyle(
                        fontSize: AppFontSize.micro,
                        color:
                            AppColors.textTertiary.withValues(alpha: 0.8))),
              ]),
        ),
      );
    }
    final thumb = handlers.refThumbOf(line, 0);
    final segCount = ref.segments.length;
    return _HoverReveal(
      builder: (hovering) => InkWell(
        key: ValueKey('band-ref-$index-0'),
        onTap: () => handlers.onPlayReference(index, -1),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          width: 74,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
                color: AppColors.textTertiary.withValues(alpha: 0.4)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(fit: StackFit.expand, children: [
            if (thumb != null)
              Image.file(File(thumb), fit: BoxFit.cover)
            else
              Container(color: Colors.black),
            // 灰调蒙层：参考是原文引用，不与右侧彩色镜头抢
            Container(color: Colors.black.withValues(alpha: 0.22)),
            Positioned(
              left: 4,
              top: 4,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(3)),
                child: const Text('参考',
                    style: TextStyle(
                        fontSize: AppFontSize.micro,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
              ),
            ),
            if (hovering)
              const Center(
                  child:
                      Icon(Icons.play_arrow, size: 20, color: Colors.white)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 2),
                color: Colors.black.withValues(alpha: 0.55),
                child: Text(
                    '${_s(ref.durationMs)}'
                    '${segCount > 1 ? ' · $segCount 镜' : ''}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: AppFontSize.micro,
                        color: Colors.white70,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _shotCard(int j, LineShot shot) {
    final expanded = expandedShot == j;
    final status = shot.localSource != null
        ? PickedMediaStatus.ready
        : handlers.shotStatus(shot.materialId);
    return InkWell(
      key: ValueKey('band-shot-$index-$j'),
      onTap: () => onExpandShot(expanded ? null : j),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      hoverColor: AppColors.hover,
      child: Container(
        width: 74,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
              color: expanded ? AppColors.accentBlue : AppColors.border,
              width: expanded ? 1.5 : 1),
          color: AppColors.surfaceCard,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              shot.thumbnailUrl != null
                  ? Image.network(shot.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(color: Colors.black))
                  : Container(
                      color: Colors.black,
                      child: shot.localSource != null
                          ? const Icon(Icons.movie_outlined,
                              size: 14, color: AppColors.textTertiary)
                          : null),
              Positioned(
                left: 3,
                top: 3,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(3)),
                  child: Text('${j + 1}',
                      style: const TextStyle(
                          fontSize: AppFontSize.micro,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ),
              Positioned(
                right: 1,
                top: 1,
                child: InkWell(
                  key: ValueKey('band-remove-shot-$index-$j'),
                  onTap: () => handlers.onRemoveShot(index, j),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(3)),
                    child:
                        const Icon(Icons.close, size: 10, color: Colors.white),
                  ),
                ),
              ),
              if (status == PickedMediaStatus.downloading)
                const Positioned(
                  left: 3,
                  bottom: 3,
                  child: SizedBox(
                      width: 9,
                      height: 9,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.2, color: Colors.white)),
                )
              else if (status == PickedMediaStatus.failed)
                Positioned(
                  left: 1,
                  bottom: 1,
                  child: InkWell(
                    key: ValueKey('band-retry-$index-$j'),
                    onTap: () => handlers.onRetryDownload(shot.materialId),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                          color: AppColors.red.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(3)),
                      child: const Icon(Icons.refresh,
                          size: 10, color: Colors.white),
                    ),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(2),
            child: Text(
                shot.allocMs != null
                    ? _s(shot.allocMs!)
                    : (shot.durationMs == null ? '?' : _s(shot.durationMs!)),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    color: shot.allocMs != null
                        ? AppColors.textSecondary
                        : AppColors.textTertiary,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ]),
      ),
    );
  }

  Widget _addCard() => InkWell(
        key: ValueKey('band-find-shots-$index'),
        onTap: () => handlers.onFindShots(index),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        hoverColor: AppColors.hover,
        child: Container(
          width: 74,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.add, size: 16, color: AppColors.textSecondary),
            const SizedBox(height: 2),
            Text(line.shots.isEmpty ? '找镜头' : '增删',
                style: const TextStyle(
                    fontSize: AppFontSize.micro, color: AppColors.textSecondary)),
          ]),
        ),
      );

  // ---- 展开的镜头详情（块内切换，不跳页面）----

  Widget _shotDetail(int j, LineShot shot) {
    final alloc = shot.allocMs;
    final src = shot.durationMs;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('第 ${j + 1} 镜',
              style: const TextStyle(
                  fontSize: AppFontSize.micro,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          const Spacer(),
          Text(src == null ? '素材时长未知' : '素材 ${_s(src)}',
              style: const TextStyle(
                  fontSize: AppFontSize.micro, color: AppColors.textTertiary)),
        ]),
        Row(children: [
          const SizedBox(
              width: 30,
              child: Text('时长',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textSecondary))),
          IconButton(
            key: ValueKey('band-alloc-minus-$index-$j'),
            visualDensity: VisualDensity.compact,
            iconSize: 13,
            onPressed: alloc == null
                ? null
                : () => handlers.onResizeShot(index, j, alloc - 500),
            icon: const Icon(Icons.remove, color: AppColors.textSecondary),
          ),
          Text(alloc == null ? '还没分' : _s(alloc),
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textPrimary,
                  fontFeatures: [FontFeature.tabularFigures()])),
          IconButton(
            key: ValueKey('band-alloc-plus-$index-$j'),
            visualDensity: VisualDensity.compact,
            iconSize: 13,
            onPressed: alloc == null
                ? null
                : () => handlers.onResizeShot(index, j, alloc + 500),
            icon: const Icon(Icons.add, color: AppColors.textSecondary),
          ),
          const Spacer(),
          Text('多退少补，旁边的镜头自动配合',
              style: TextStyle(
                  fontSize: AppFontSize.micro,
                  color: AppColors.textTertiary.withValues(alpha: 0.8))),
        ]),
        if (src != null && shot.allocMs != null)
          Builder(builder: (context) {
            final bar = _TrimBar(
              key: ValueKey('band-trim-$index-$j'),
              shot: shot,
              frames: handlers.shotFramesOf(shot),
              onTrim: (ms) => handlers.onTrimShot(index, j, ms),
              onResize: (ms) => handlers.onResizeShot(index, j, ms),
            );
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(
                        width: 30,
                        child: Text('取段',
                            style: TextStyle(
                                fontSize: AppFontSize.micro,
                                color: AppColors.textSecondary))),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [bar, bar.rangeCaption()]),
                    ),
                  ]),
            );
          }),
        Row(children: [
          const SizedBox(
              width: 30,
              child: Text('速度',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textSecondary))),
          // 放慢充满会产生 0.68x 这类速度：不在预设里就单独亮出来，
          // 不能让四个灰档骗人说「没变速」
          if (!const [0.75, 1.0, 1.25, 1.5].contains(shot.speed))
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accentBlue.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppColors.accentBlue),
                ),
                child: Text('${shot.speed}x',
                    style: const TextStyle(
                        fontSize: AppFontSize.micro,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accentBlueLight)),
              ),
            ),
          for (final v in const [0.75, 1.0, 1.25, 1.5])
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: InkWell(
                key: ValueKey('band-speed-$index-$j-$v'),
                onTap: () => handlers.onSpeedShot(index, j, v),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: shot.speed == v
                        ? AppColors.accentBlue.withValues(alpha: 0.16)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: shot.speed == v
                            ? AppColors.accentBlue
                            : AppColors.border),
                  ),
                  child: Text('${v}x',
                      style: TextStyle(
                          fontSize: AppFontSize.micro,
                          fontWeight:
                              shot.speed == v ? FontWeight.w600 : FontWeight.w400,
                          color: shot.speed == v
                              ? AppColors.accentBlueLight
                              : AppColors.textSecondary)),
                ),
              ),
            ),
          const Spacer(),
          Text('换速度会把起点归零',
              style: TextStyle(
                  fontSize: AppFontSize.micro,
                  color: AppColors.textTertiary.withValues(alpha: 0.8))),
        ]),
        // 小行切分：把台词的某一段指定给从这一镜起的镜头组
        if (voiced && j > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              key: ValueKey('band-split-subline-$index-$j'),
              onTap: () => handlers.onSplitSubline(index, j),
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('✂ 从这一镜分小行（指定这段台词落在哪几镜）',
                    style: const TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.accentBlueLight)),
              ),
            ),
          ),
      ]),
    );
  }

  // ---- 配音行（紧凑）：状态 · 音色 · 时长 · 生成 · 试听 ----

  Widget _voiceRow() {
    final vo = line.voiceover;
    final state = line.voiceState;
    final voiceName = line.voiceId == null
        ? null
        : (VoiceCatalog.byId(line.voiceId!)?.ref.name ?? line.voiceId);
    return Row(children: [
      const Icon(Icons.graphic_eq, size: 12, color: AppColors.textTertiary),
      const SizedBox(width: AppSpacing.xs),
      // 音色（点击弹菜单：换音色 / 语速）
      PopupMenuButton<String>(
        key: ValueKey('band-voice-menu-$index'),
        tooltip: '音色与语速',
        onSelected: (v) {
          if (v == 'pick') {
            handlers.onPickVoice(index);
          } else {
            handlers.onSpeechRate(index, int.parse(v));
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'pick', height: 32, child: Text('更换音色')),
          const PopupMenuDivider(height: 8),
          for (final (rate, label) in const [
            (-25, '语速 0.75x'),
            (0, '语速 1x'),
            (25, '语速 1.25x'),
            (50, '语速 1.5x'),
          ])
            PopupMenuItem(
              value: '$rate',
              height: 32,
              child: Row(children: [
                if (line.speechRate == rate)
                  const Icon(Icons.check, size: 12, color: AppColors.accentBlue)
                else
                  const SizedBox(width: 12),
                const SizedBox(width: 6),
                Text(label),
              ]),
            ),
        ],
        child: Text(
            '${voiceName ?? '选择音色'}'
            '${line.speechRate != 0 ? ' · ${1 + line.speechRate / 100}x' : ''}',
            style: TextStyle(
                fontSize: AppFontSize.caption,
                color: voiceName == null
                    ? AppColors.accentBlueLight
                    : AppColors.textSecondary)),
      ),
      const SizedBox(width: AppSpacing.md),
      if (vo != null) ...[
        InkWell(
          key: ValueKey('band-play-voice-$index'),
          onTap: () => handlers.onTogglePlayVoice(index),
          child: Row(children: [
            Icon(playing ? Icons.stop : Icons.play_arrow,
                size: 14, color: AppColors.textPrimary),
            const SizedBox(width: 2),
            Text(_s(vo.durationMs),
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textPrimary,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ]),
        ),
        const SizedBox(width: AppSpacing.md),
      ],
      if (state == LineVoiceState.stale)
        const Text('内容已改，配音是旧的',
            style:
                TextStyle(fontSize: AppFontSize.micro, color: AppColors.orange)),
      const Spacer(),
      // 行级字幕覆盖：素材自带字幕位置不同时按行改
      PopupMenuButton<String>(
        key: ValueKey('band-subtitle-$index'),
        tooltip: line.subtitleOverride == null
            ? '这一行的字幕（跟随全局）'
            : '这一行的字幕（已自定义）',
        onSelected: (v) => v == 'edit'
            ? handlers.onEditLineSubtitle(index)
            : handlers.onClearLineSubtitle(index),
        itemBuilder: (_) => [
          const PopupMenuItem(
              value: 'edit', height: 32, child: Text('自定义这一行的字幕…')),
          if (line.subtitleOverride != null)
            const PopupMenuItem(
                value: 'clear', height: 32, child: Text('恢复跟随全局')),
        ],
        child: Icon(Icons.subtitles_outlined,
            size: 13,
            color: line.subtitleOverride == null
                ? AppColors.textTertiary
                : AppColors.accentBlueLight),
      ),
      const SizedBox(width: AppSpacing.sm),
      SizedBox(
        height: 24,
        child: TextButton.icon(
          key: ValueKey('band-generate-$index'),
          onPressed: generating ? null : () => handlers.onGenerateVoice(index),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            textStyle: const TextStyle(
                fontSize: AppFontSize.micro, fontWeight: FontWeight.w600),
          ),
          icon: generating
              ? const SizedBox(
                  width: 9,
                  height: 9,
                  child: CircularProgressIndicator(strokeWidth: 1.2))
              : Icon(vo == null ? Icons.mic : Icons.refresh, size: 11),
          label: Text(generating
              ? '生成中…'
              : (vo == null
                  ? '生成配音'
                  : (state == LineVoiceState.stale ? '重新生成' : '重配'))),
        ),
      ),
    ]);
  }

  // ---- 画面行（紧凑）：手填时长 / 随素材 ----

  Widget _visualRow() {
    final seconds =
        line.manualMs == null ? '' : (line.manualMs! / 1000).toStringAsFixed(1);
    return Row(children: [
      const Icon(Icons.timer_outlined, size: 12, color: AppColors.textTertiary),
      const SizedBox(width: AppSpacing.xs),
      const Text('时长',
          style: TextStyle(
              fontSize: AppFontSize.caption, color: AppColors.textSecondary)),
      const SizedBox(width: AppSpacing.sm),
      SizedBox(
        width: 76,
        height: 26,
        child: TextFormField(
          key: ValueKey('band-manual-ms-${line.id}'),
          initialValue: seconds,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(
              fontSize: AppFontSize.caption, color: AppColors.textPrimary),
          decoration: const InputDecoration(
            isDense: true,
            suffixText: '秒',
            hintText: '随素材',
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          ),
          onChanged: (v) {
            final parsed = double.tryParse(v.trim());
            handlers.onManualMs(index,
                parsed == null || parsed <= 0 ? null : (parsed * 1000).round());
          },
        ),
      ),
      const SizedBox(width: AppSpacing.sm),
      const Text('不填则跟随所选素材',
          style: TextStyle(
              fontSize: AppFontSize.micro, color: AppColors.textTertiary)),
    ]);
  }

  static String _s(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';
}
