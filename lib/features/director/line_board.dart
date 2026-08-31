import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'scroll_into_view.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/voice_catalog.dart';
import '../../core/script/bgm_rail.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/shot_allocation.dart';
import '../../core/subtitle/subtitle_style.dart';
import '../picking/picked_media_cache.dart';
import 'line_text_picker.dart';

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

  /// 取段胶片条的素材帧与宽高比（没抽好返回 null，条退回纯色）。
  /// 帧格比例锁素材原比例——竖屏素材就是竖格，窗口多宽都不拉伸
  final ({List<String> frames, double aspect})? Function(LineShot shot)
      shotFramesOf;

  /// 原位播放一个镜头的选用段（在卡上播，不弹窗）；再点一次停
  final void Function(int index, int shotIndex) onPlayShot;

  /// 取段条拖拽松手：重播这一镜听调整后的效果
  final void Function(int index, int shotIndex) onTrimDone;

  /// 这一行当下生效的字幕样式（草稿 > 行级覆盖 > 全局）——
  /// 镜头卡上按它画字幕缩略，改样式时几张卡同时变
  final SubtitleStyle Function(ScriptLine line) subtitleStyleOf;

  /// 改第 [screenIndex] 屏的字（null = 这屏回到原文，'' = 这屏不出字）
  final void Function(int index, int screenIndex, String? text) onScreenText;

  /// 把第 [screenIndex] 屏并回上一屏（撤掉这一刀）
  final void Function(int index, int screenIndex) onScreenMerge;

  /// 在行时间轴 [atMs] 处切一刀（拆屏 / 打轴都走它）
  final void Function(int index, int atMs) onScreenCut;

  /// 这一行的字幕恢复全自动（清掉所有切点与改字）
  final void Function(int index) onScreenReset;

  /// 给全片缺逐字时间的行重配一次音（补上之后才能手工分屏、打轴）
  final VoidCallback onFixTimings;

  /// 改这一镜的**素材原声**音量（null = 回到跟随整片）
  final void Function(int index, int shotIndex, double? volume)
      onShotSourceVolume;

  /// 整片的原声基调（这一镜没单独设时显示它）
  /// 这一行没单独设过时，原声该多大。**必须和播放用的是同一个数**——
  /// 画面行满音量、配音行跟全片。以前这里直接塞全片基调，于是画面行
  /// 显示「静音」却在满音量播，人一拖滑杆就把 0 写死了
  final double Function(ScriptLine line) defaultSourceVolumeOf;

  /// 这一行**实际**用的音色与语速（行上没设就是本片基调）。
  /// 界面显示的必须是有效值——显示行上的值，会让「跟随本片」的行看起来
  /// 像是没设过音色
  final String? Function(ScriptLine line) voiceIdOf;
  final int Function(ScriptLine line) speechRateOf;

  /// 这一行的配音新不新（拿有效值判定）
  final LineVoiceState Function(ScriptLine line) voiceStateOf;

  /// 划词建镜：人在台词上选中几个字，给出**词序号**区间 `[start, end)`
  final void Function(int lineIndex, int startWord, int endWord) onPickWords;

  /// 这一段配乐的曲子在本地的状态（null = 这段没配乐 / 没有下载器）
  final PickedMediaStatus? Function(int materialId) bgmStatus;

  /// 重下这首配乐（下砸了之后的自救入口）
  final void Function(int materialId) onRetryBgm;

  /// 打轴：正在原位播这一镜时，在当前播放位置把字幕切成两屏
  final void Function(int index, int shotIndex) onSubtitleCutHere;
  final void Function(int index, int? manualMs) onManualMs;
  final void Function(int index) onPickVoice;
  final void Function(int index, int rate) onSpeechRate;
  final void Function(int index) onGenerateVoice;
  final void Function(int index) onTogglePlayVoice;
  final void Function(int index, int segIndex) onPlayReference;
  final void Function(int index, int segIndex) onUseReference;
  final void Function(int index) onUploadReference;

  final PickedMediaStatus? Function(int materialId) shotStatus;
  final void Function(int materialId) onRetryDownload;

  /// 参考分镜的缩略图本地路径（抽帧后缓存）；null = 还没抽好
  final String? Function(ScriptLine line, int segIndex) refThumbOf;

  /// 这一句所属的配乐段（轨段下标, 段本身, 是不是段首）
  final ({int index, BgmRailSegment seg, bool isHead}) Function(int lineIndex)
      bgmOf;

  /// 从这一句开始换一首（切一刀）
  final void Function(int lineIndex) onBgmSplit;

  /// 点段首色带：换曲 / 音量 / 与上一段合并
  final void Function(int segIndex) onBgmEdit;

  /// 分界上下挪一句（-1 上移、+1 下移）
  final void Function(int segIndex, int delta) onBgmMoveBoundary;

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
    required this.onPlayShot,
    required this.onTrimDone,
    required this.subtitleStyleOf,
    required this.onScreenText,
    required this.onScreenMerge,
    required this.onScreenCut,
    required this.onScreenReset,
    required this.onFixTimings,
    required this.onShotSourceVolume,
    required this.defaultSourceVolumeOf,
    required this.voiceIdOf,
    required this.speechRateOf,
    required this.voiceStateOf,
    required this.onPickWords,
    required this.bgmStatus,
    required this.onRetryBgm,
    required this.onSubtitleCutHere,
    required this.onManualMs,
    required this.onPickVoice,
    required this.onSpeechRate,
    required this.onGenerateVoice,
    required this.onTogglePlayVoice,
    required this.onPlayReference,
    required this.onUseReference,
    required this.onUploadReference,
    required this.shotStatus,
    required this.onRetryDownload,
    required this.refThumbOf,
    required this.bgmOf,
    required this.onBgmSplit,
    required this.onBgmEdit,
    required this.onBgmMoveBoundary,
  });
}

class LineBoard extends StatelessWidget {
  final ScriptDoc doc;
  final int selected;

  /// 多选中的行（下标）。空 = 只选了 [selected] 那一行
  final Set<int> multiSelected;

  /// 展开镜头详情的位置：(行下标, 镜头下标)；null = 都收着
  final (int, int)? expandedShot;
  final ValueChanged<(int, int)?> onExpandShot;
  final Set<String> generatingLineIds;
  final String? playingLineId;

  /// 预览播放位置当前落在的行：块点亮并自动滚到可见（预览是主角）
  final int? previewLineIndex;

  /// Agent 正在为哪一行找镜头（`script shots` 那一步，还没写进来）
  final int? searchingLineIndex;

  /// 要把哪一行滚到眼前（Agent 干活时界面跟着它走）。
  /// 给了就压过 [previewLineIndex]——人得看见 Agent 正在动哪一行
  final int? focusLineIndex;

  /// 正在原位播放的卡（'ref_行id' / 'shot_行id_镜下标'）与共享播放器
  /// 画面——谁在播，画面就挂到谁的卡上
  final String? inlineKey;
  final Widget? inlineVideo;

  /// 原位播放到哪儿了（素材坐标，毫秒）——播这一镜时字幕跟着当前屏走。
  /// 用 ValueListenable 只让那一块字重建，不带着整块板子每秒刷几次
  final ValueListenable<int>? inlinePosition;
  final LineBoardHandlers handlers;
  final ScrollController? controller;

  const LineBoard({
    super.key,
    required this.doc,
    required this.selected,
    this.multiSelected = const {},
    required this.expandedShot,
    required this.onExpandShot,
    required this.generatingLineIds,
    required this.playingLineId,
    this.previewLineIndex,
    this.focusLineIndex,
    this.searchingLineIndex,
    this.inlineKey,
    this.inlineVideo,
    this.inlinePosition,
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
      itemBuilder: (context, i) => ScrollIntoView(
        key: ValueKey('band-${doc.lines[i].id}'),
        active: i == (focusLineIndex ?? previewLineIndex),
        child: _LineBand(
          index: i,
          line: doc.lines[i],
          agentFocused: focusLineIndex == i,
          searchingShots: searchingLineIndex == i,
          voiceState: doc.voiceStateOf(doc.lines[i]),
          selected: multiSelected.isEmpty
              ? i == selected
              : multiSelected.contains(i),
          expandedShot: expandedShot != null && expandedShot!.$1 == i
              ? expandedShot!.$2
              : null,
          onExpandShot: (shot) => onExpandShot(shot == null ? null : (i, shot)),
          generating: generatingLineIds.contains(doc.lines[i].id),
          playing: playingLineId == doc.lines[i].id,
          previewing: i == previewLineIndex,
          inlineKey: inlineKey,
          inlineVideo: inlineVideo,
          inlinePosition: inlinePosition,
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
  final ({List<String> frames, double aspect})? frames;
  final ValueChanged<int> onTrim;
  final ValueChanged<int> onResize;

  /// 拖拽松手：调完取段立即重播这一镜听效果（用户的工作流——
  /// 调时长把字幕对到分镜上，每次调完听一遍确认）
  final VoidCallback onDone;

  const _TrimBar({
    super.key,
    required this.shot,
    required this.frames,
    required this.onTrim,
    required this.onResize,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final src = shot.durationMs!;
    final alloc = shot.allocMs ?? 0;
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      // **整条是成片时间轴**（用户定的口径）：这条素材按当前倍速最多能
      // 出多长（素材长 ÷ 倍速）。1.5 秒就是成片里的 1.5 秒，与倍速无关；
      // 倍速只改变「这条素材能出多长」。
      //
      // 算术搬到 trimBarMetrics 里去了：埋在 build 里测不到，而这段真机
      // 上崩过——取段起点悬在素材之外时 clamp 上下限颠倒，Release 包把
      // 整块面板渲染成一片灰
      final m = trimBarMetrics(
        width: w,
        sourceMs: src,
        trimStartMs: shot.trimStartMs,
        allocMs: alloc,
        speed: shot.speed,
      );
      final outTotal = src / shot.speed;
      final pxPerMs = outTotal <= 0 ? 0.0 : w / outTotal;
      final winLeft = m.left;
      final winWidth = m.width;
      final fs = frames;
      const barH = 64.0;
      // 格数随条宽自适应：格宽 = 条高 × 素材宽高比（比例锁定，
      // 窗口多宽格子只会变多，永远不拉伸）；从缓存帧里按时间均匀取
      final cells = <String>[];
      if (fs != null && fs.frames.isNotEmpty) {
        final cellW = barH * fs.aspect;
        final n = (w / cellW).ceil().clamp(1, 64);
        for (var i = 0; i < n; i++) {
          final idx =
              ((i + 0.5) / n * fs.frames.length).floor().clamp(0, fs.frames.length - 1);
          cells.add(fs.frames[idx]);
        }
      }
      return SizedBox(
        height: barH,
        child: Stack(children: [
          // 底条：素材全长——有帧铺帧（看得见画面），没帧退纯色
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: cells.isEmpty
                  ? const ColoredBox(color: AppColors.surfaceCard)
                  : Row(children: [
                      for (final f in cells)
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
          if (cells.isNotEmpty) ...[
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
                    (shot.trimStartMs + d.delta.dx / pxPerMs * shot.speed)
                        .round()),
                onHorizontalDragEnd: (_) => onDone(),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // 有帧时窗口只描边不盖色——里面就是选中的画面本身；
                    // 纯色条才需要填充示意
                    color: cells.isEmpty
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
                onHorizontalDragUpdate: (d) =>
                    onResize((alloc + d.delta.dx / pxPerMs).round()),
                onHorizontalDragEnd: (_) => onDone(),
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

  /// 取段的数字口径——**全是成片时间**：左「0.0s ~ 2.5s」（这一镜在
  /// 成片里从素材的哪一刻起、用多长），右「这条素材可出 6.4s」
  /// （素材长 ÷ 倍速）
  Widget rangeCaption() {
    final from = (shot.trimStartMs / shot.speed).round();
    final to = from + (shot.allocMs ?? 0);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(children: [
        Text('${_s(from)} ~ ${_s(to)}',
            style: const TextStyle(
                fontSize: AppFontSize.micro,
                color: AppColors.textSecondary,
                fontFeatures: [FontFeature.tabularFigures()])),
        const Spacer(),
        Text('这条素材可出 ${_s((shot.durationMs! / shot.speed).round())}',
            style: const TextStyle(
                fontSize: AppFontSize.micro,
                color: AppColors.textTertiary,
                fontFeatures: [FontFeature.tabularFigures()])),
      ]),
    );
  }

  static String _s(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';
}

/// 一屏字幕的输入框：**预填真实文字**（不是灰提示）——想改一个字就改
/// 一个字，不用把整段重打。失焦/回车才落盘，避免每敲一个字就重建预览
class _ScreenTextField extends StatefulWidget {
  final String text;

  /// null = 这屏回到原文（清空输入框）；非空 = 这屏按你写的显示
  final ValueChanged<String?> onChanged;

  const _ScreenTextField({
    super.key,
    required this.text,
    required this.onChanged,
  });

  @override
  State<_ScreenTextField> createState() => _ScreenTextFieldState();
}

class _ScreenTextFieldState extends State<_ScreenTextField> {
  late final TextEditingController _c =
      TextEditingController(text: widget.text);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  void _commit() {
    final t = _c.text.trim();
    // 没动过就不落盘——别把自动结果悄悄固化成手写
    if (t == widget.text.trim()) return;
    widget.onChanged(t.isEmpty ? null : t);
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        focusNode: _focus,
        style: const TextStyle(fontSize: AppFontSize.caption, height: 1.3),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          hintText: '这屏显示的字',
        ),
        onSubmitted: (_) => _commit(),
      );
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

class _LineBand extends StatelessWidget {
  final int index;
  final ScriptLine line;

  /// Agent 正在**为这一行找镜头**（`script shots` 那一步）。
  ///
  /// 找镜头只是检索、还没写进来，所以这段时间里坑位一直是「+ 找镜头」
  /// ——而播报那头在热火朝天地报「找到 946 条、20/20 条能用、正在挑」。
  /// 人看到的是：它在忙，可界面什么都没发生，和没干一模一样。
  /// 所以这一格自己得动起来
  final bool searchingShots;

  /// Agent 此刻正在做的就是这一行。**比人自己选中更醒目**——
  /// 可视模式的全部意义就是让人一眼看出「它现在在动哪儿」，
  /// 和普通选中长一个样的话，人得盯着播报条读字才知道
  final bool agentFocused;

  /// 这一行配音的**有效**状态（doc.voiceStateOf 算好的）。
  /// 不在这儿用 line.voiceState 自己算：那个看不见基调变化，
  /// 换了全片音色之后点还是绿的，人以为都好了，导出才发现前后音色不一样
  final LineVoiceState voiceState;
  final bool selected;
  final int? expandedShot;
  final ValueChanged<int?> onExpandShot;
  final bool generating;
  final bool playing;

  /// 预览播放位置正落在这一行
  final bool previewing;
  final String? inlineKey;
  final Widget? inlineVideo;

  /// 原位播放到哪儿了（素材坐标，毫秒）——播这一镜时字幕跟着当前屏走。
  /// 用 ValueListenable 只让那一块字重建，不带着整块板子每秒刷几次
  final ValueListenable<int>? inlinePosition;
  final LineBoardHandlers handlers;

  const _LineBand({
    required this.index,
    required this.line,
    required this.agentFocused,
    required this.searchingShots,
    required this.voiceState,
    required this.selected,
    required this.expandedShot,
    required this.onExpandShot,
    required this.generating,
    required this.playing,
    required this.previewing,
    this.inlineKey,
    this.inlineVideo,
    this.inlinePosition,
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
        key: agentFocused ? const Key('agent-focus-band') : null,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: agentFocused
              ? Color.lerp(
                  AppColors.surfaceRaised, AppColors.accentBlue, 0.10)!
              : previewing
                  ? Color.lerp(
                      AppColors.surfaceRaised, AppColors.accentBlue, 0.06)!
                  : AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
              color:
                  (agentFocused || selected) ? AppColors.accentBlue : AppColors.border,
              width: agentFocused ? 2 : (selected ? 1.2 : 1)),
          // 正在被操作的那一行**发光**：滚过来的同时人眼就被带过去了，
          // 不用去读播报条上的字
          boxShadow: agentFocused
              ? [
                  BoxShadow(
                      color: AppColors.accentBlue.withValues(alpha: 0.28),
                      blurRadius: 16,
                      spreadRadius: 1),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md + 13, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
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
          // 配乐轨：块左缘的一条色带，段首挂曲名。整片被若干刀切成
          // 连续段——「从这一句开始换一首」而不是「第几行到第几行」
          Positioned(left: 3, top: 0, bottom: 0, width: 10, child: _bgmRail()),
        ]),
      ),
    );
  }

  /// 配乐色带（块左缘）：同一段同一个颜色，段首显示曲名。
  /// 悬停：段首出「换曲」，其余出「从这句换一首」
  Widget _bgmRail() {
    final info = handlers.bgmOf(index);
    final seg = info.seg;
    // 曲子在不在本地：**在干活的地方就要看得见**，不能等到点导出
    // 才告诉人「还没下载」（真机踩过：配乐下砸了全程无感，导出被拦）
    final mid = seg.material?.id;
    final status = mid == null ? null : handlers.bgmStatus(mid);
    final failed = status == PickedMediaStatus.failed;
    final waiting = status == PickedMediaStatus.downloading ||
        status == PickedMediaStatus.absent;
    final base = seg.silent
        ? AppColors.textTertiary.withValues(alpha: 0.22)
        : _bgmColors[info.index % _bgmColors.length];
    final color = failed
        ? AppColors.red
        : (waiting ? base.withValues(alpha: 0.35) : base);
    final tip = failed
        ? '这首配乐没下下来，点一下重试'
        : (waiting
            ? '配乐正在下载到本地…'
            : (info.isHead ? '点一下换曲 / 调音量' : '从这一句起换一首'));
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: _HoverReveal(
        builder: (hovering) => Stack(children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(
                  top: info.isHead ? 3 : 0,
                  bottom: seg.endLine == index ? 3 : 0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          // 没就绪的段首常驻一个记号：转圈 = 在下，叹号 = 下砸了
          if (info.isHead && (failed || waiting))
            Positioned(
              left: 0,
              right: 0,
              top: 5,
              child: failed
                  ? const Icon(Icons.priority_high, size: 9, color: Colors.white)
                  : const SizedBox(
                      width: 8,
                      height: 8,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.4, color: Colors.white70)),
            ),
          if (hovering)
            Positioned.fill(
              child: InkWell(
                key: ValueKey(failed
                    ? 'band-bgm-retry-$index'
                    : (info.isHead
                        ? 'band-bgm-edit-$index'
                        : 'band-bgm-split-$index')),
                // 下砸了的段：点一下就是重下，别再让人先去开编辑面板
                onTap: () => failed
                    ? handlers.onRetryBgm(mid!)
                    : (info.isHead
                        ? handlers.onBgmEdit(info.index)
                        : handlers.onBgmSplit(index)),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.35),
                  alignment: Alignment.center,
                  child: Icon(
                      failed
                          ? Icons.refresh
                          : (info.isHead
                              ? Icons.music_note
                              : Icons.content_cut),
                      size: 9,
                      color: Colors.white),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  /// 段的配色（轮转）：相邻段颜色不同，一眼看出「这里换歌了」
  static const _bgmColors = <Color>[
    Color(0xFF7C5CFF),
    Color(0xFF00B8A9),
    Color(0xFFFF7A45),
    Color(0xFF3DA5FF),
    Color(0xFFE05FA6),
  ];

  // ---- 块头：行号 · 状态点 · 台词（只读，编辑在左栏）----

  Widget _header() {
    final state = voiceState;
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
        // 选中的这一行才让划词：整块板子都摆成可选文本的话，随手一拖
        // 就冒出一堆按钮，反而碍事
        child: voiced && selected && line.voiceover != null
            ? LineTextPicker(
                text: line.text.trim(),
                words: line.voiceover!.words,
                takenWordRanges: [
                  for (final s in line.shots)
                    if (s.boundToWords)
                      (start: s.startWord!, end: s.endWord!),
                ],
                onPick: (a, b) => handlers.onPickWords(index, a, b),
                // 点台词也算点这一行——可选文本会把点击吃掉，
                // 不转出去的话，划过词的那一行点了预览不跳
                onTapText: () => handlers.onFocusLine(index),
              )
            : Text(
                voiced ? line.text.trim() : '画面行（无台词，只有画面）',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: AppFontSize.body,
                    height: 1.4,
                    color:
                        voiced ? AppColors.textPrimary : AppColors.textTertiary),
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
  /// 我的镜头区：一行铺开（字幕归属在镜头上，由详情里的字幕框表达，
  /// 不再用小行分组）
  Widget _sublineRows() {
    return SizedBox(
      height: 132,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (var j = 0; j < line.shots.length; j++) ...[
            _shotCard(j, line.shots[j]),
            const SizedBox(width: AppSpacing.sm),
          ],
          _addCard(),
        ],
      ),
    );
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
            if (inlineKey == 'ref_${line.id}' && inlineVideo != null)
              inlineVideo!
            else if (thumb != null)
              Image.file(File(thumb), fit: BoxFit.cover)
            else
              Container(color: Colors.black),
            // 灰调蒙层：参考是原文引用，不与右侧彩色镜头抢（播放时不压）
            if (inlineKey != 'ref_${line.id}')
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
              // 缩略图**本地帧优先**：miaoa 的 thumbnailUrl 是签名地址，
              // 过期就黑卡（真机发生过）。素材本体已固定到本地，
              // 封面直接用本地抽帧——凡是进入方案的都不依赖会过期的外链
              if (inlineKey == 'shot_${line.id}_$j' && inlineVideo != null)
                Stack(fit: StackFit.expand, children: [
                  inlineVideo!,
                  // 播这一镜时把它的字幕叠上：听到的话和看到的字对上
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 3, vertical: 2),
                      color: Colors.black.withValues(alpha: 0.55),
                      child: ValueListenableBuilder<int>(
                        valueListenable: inlinePosition ?? _noPosition,
                        builder: (context, pos, _) => Text(
                        _playingScreenText(j, pos),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: AppFontSize.micro,
                            height: 1.3,
                            color: Colors.white),
                      )),
                    ),
                  ),
                ])
              else
              Builder(builder: (context) {
                final local = handlers.shotFramesOf(shot);
                if (local != null && local.frames.isNotEmpty) {
                  return Image.file(File(local.frames.first),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Container(color: Colors.black));
                }
                return shot.thumbnailUrl != null
                    ? Image.network(shot.thumbnailUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            Container(color: Colors.black))
                    : Container(
                        color: Colors.black,
                        child: shot.localSource != null
                            ? const Icon(Icons.movie_outlined,
                                size: 14, color: AppColors.textTertiary)
                            : null);
              }),
              // 原位播放选用段：悬停出 ▶（平时不挡「点卡展开详情」），
              // 在卡上播不弹窗；播放中常驻 ⏹ 再点停
              _HoverReveal(
                builder: (hovering) =>
                    hovering || inlineKey == 'shot_${line.id}_$j'
                        ? Center(
                            child: InkWell(
                              key: ValueKey('band-play-shot-$index-$j'),
                              onTap: () => handlers.onPlayShot(index, j),
                              borderRadius: BorderRadius.circular(999),
                              child: Container(
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                    color:
                                        Colors.black.withValues(alpha: 0.45),
                                    shape: BoxShape.circle),
                                child: Icon(
                                    inlineKey == 'shot_${line.id}_$j'
                                        ? Icons.stop
                                        : Icons.play_arrow,
                                    size: 14,
                                    color: Colors.white),
                              ),
                            ),
                          )
                        : const SizedBox.expand(),
              ),
              // 卡上直接看到这一镜的字幕（位置/颜色/遮罩按真实样式缩放）
              // ——不打开任何面板就能一眼扫完整句每镜显示什么字
              if (voiced && inlineKey != 'shot_${line.id}_$j')
                Positioned.fill(child: _cardSubtitle(j)),
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
              // **「在忙」要一眼看得出来**：此前下载中只有角落里一个 9 像素的
              // 小转圈，人看到的就是一块黑图——和「坏了」长得一模一样。
              // 验收时人在旁边指着屏幕问的就是这个：「这红按钮、没首帧，
              // 是不是出问题了？」其实只是还在下载
              if (status == PickedMediaStatus.downloading)
                Positioned.fill(
                  child: Tooltip(
                    message: '正在下载这条素材…',
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.45),
                      child: const Center(
                        child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white)),
                      ),
                    ),
                  ),
                )
              else if (status == PickedMediaStatus.failed)
                Positioned.fill(
                  child: Tooltip(
                    message: '这条素材没下下来，点一下重试',
                    child: InkWell(
                      key: ValueKey('band-retry-$index-$j'),
                      onTap: () => handlers.onRetryDownload(shot.materialId),
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.45),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                                color: AppColors.red.withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(4)),
                            child: const Icon(Icons.refresh,
                                size: 14, color: Colors.white),
                          ),
                        ),
                      ),
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 74,
          decoration: BoxDecoration(
            color: searchingShots
                ? Color.lerp(
                    Colors.transparent, AppColors.accentBlue, 0.12)
                : null,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
                color:
                    searchingShots ? AppColors.accentBlue : AppColors.border),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            // **正在给这一行找镜头时，这一格自己转起来**：找镜头是纯检索，
            // 要过一会儿才有东西填进来，这段时间里一动不动的加号
            // 和「没在干活」没有区别
            if (searchingShots) ...[
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.6, color: AppColors.accentBlue)),
              const SizedBox(height: 4),
              const Text('正在找…',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.accentBlue)),
            ] else ...[
              const Icon(Icons.add, size: 16, color: AppColors.textSecondary),
              const SizedBox(height: 2),
              Text(line.shots.isEmpty ? '找镜头' : '添加分镜',
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textSecondary)),
            ],
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
              onDone: () => handlers.onTrimDone(index, j),
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
        // 这一镜的**素材原声**：音效要能听见，杂音要能压掉。
        // 不设就跟随整片（预览下方那根「原声」滑杆）
        _shotSourceVolumeRow(j),
        // 这一镜时间窗里的**字幕屏**：一屏一行，左边是它在成片里的
        // 入点、中间直接改字、行尾能拆开 / 并回上一屏 / 设为不出字。
        // 屏跟着语言走、镜头跟着画面走——改镜头时长，屏自愈
        if (voiced) _screenList(j),
      ]),
    );
  }

  /// 镜头卡上的字幕缩略：位置按 bottomRatio、颜色/遮罩照真实样式，
  /// 字号按比例缩放后夹在可读区间（卡片只有几十像素宽，严格等比会
  /// 糊成一条；真实字号以中栏预览与成片为准）
  Widget _cardSubtitle(int j) {
    final rows = _screensOfShot(j);
    final text = rows.isEmpty ? '' : rows.first.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final style = handlers.subtitleStyleOf(line);
    return LayoutBuilder(builder: (context, c) {
      final h = c.maxHeight;
      final fontSize = (h * style.fontRatio * 2.0).clamp(7.0, 13.0);
      final color = style.colorHex != null
          ? Color(int.parse('FF${style.colorHex}', radix: 16))
          : (style.preset == SubtitlePreset.yellowOutline
              ? const Color(0xFFFFD900)
              : Colors.white);
      final hasBacking = style.preset == SubtitlePreset.whiteBox ||
          style.preset == SubtitlePreset.blurBox;
      return IgnorePointer(
        child: Padding(
          padding: EdgeInsets.only(bottom: h * style.bottomRatio, left: 2, right: 2),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              padding: hasBacking
                  ? const EdgeInsets.symmetric(horizontal: 2, vertical: 1)
                  : EdgeInsets.zero,
              decoration: hasBacking
                  ? BoxDecoration(
                      // 黑条按真实半透明黑；毛玻璃在卡上用浅色示意
                      // （真磨砂在预览与成片里）
                      color: style.preset == SubtitlePreset.whiteBox
                          ? Colors.black.withValues(alpha: 0.55)
                          : Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(2),
                    )
                  : null,
              child: Text(
                rows.length > 1 ? '$text  +${rows.length - 1}屏' : text,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontSize,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  color: color,
                  shadows: hasBacking
                      ? null
                      : const [
                          Shadow(color: Colors.black, blurRadius: 2),
                          Shadow(color: Colors.black, blurRadius: 2),
                        ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  /// 这一镜的原声音量行
  Widget _shotSourceVolumeRow(int j) {
    final shot = line.shots[j];
    final own = shot.sourceVolume;
    final value = own ?? handlers.defaultSourceVolumeOf(line);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        const SizedBox(
            width: 30,
            child: Text('原声',
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    color: AppColors.textSecondary))),
        Expanded(
          child: SliderTheme(
            data: const SliderThemeData(
              trackHeight: 2,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: 4),
              overlayShape: RoundSliderOverlayShape(overlayRadius: 8),
            ),
            child: Slider(
              key: ValueKey('band-shot-volume-$index-$j'),
              value: value.clamp(0.0, 1.0),
              activeColor: AppColors.accentBlue,
              onChanged: (v) => handlers.onShotSourceVolume(index, j, v),
            ),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(value <= 0.001 ? '静音' : '${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: AppFontSize.micro,
                  // 静音是「这一镜听不见」，不是一个普通读数——用警示色，
                  // 不然人翻半天也找不到自己哪一镜哑了
                  color: value <= 0.001
                      ? AppColors.orange
                      : AppColors.textTertiary,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ),
        // 单独设过就标出来，并给一键回到默认。
        //
        // **这一格必须显眼**：真机上一条画面行被写死成 0.0，人调全片原声
        // 怎么都救不回来（逐镜的设定压着全片），只能在这里点掉
        if (own != null) ...[
          const SizedBox(width: 6),
          InkWell(
            key: ValueKey('band-shot-volume-reset-$index-$j'),
            onTap: () => handlers.onShotSourceVolume(index, j, null),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.accentBlue.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppRadius.xs),
              ),
              child: Text(
                  line.type == ScriptLineType.voiced ? '跟随整片' : '恢复默认',
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.accentBlueLight)),
            ),
          ),
        ],
      ]),
    );
  }

  /// 这一镜的时间窗（行时间轴，成片时间）
  (int, int) _shotWindow(int j) {
    var start = 0;
    for (var i = 0; i < j && i < line.shots.length; i++) {
      start += line.shots[i].allocMs ?? 0;
    }
    return (start, start + (line.shots[j].allocMs ?? 0));
  }

  /// 与这一镜**相交**的字幕屏（跨镜的屏在两边都看得到）。
  /// 与预览层、成片导出取的是同一份派生——四处显示永远一致
  List<({int index, int startMs, int endMs, String text})> _screensOfShot(
      int j) {
    final (start, end) = _shotWindow(j);
    final all = line.subtitleScreensAt(
        maxChars: handlers.subtitleStyleOf(line).maxCharsPerScreen);
    return [
      for (var i = 0; i < all.length; i++)
        if (all[i].endMs > start && all[i].startMs < end)
          (
            index: i,
            startMs: all[i].startMs,
            endMs: all[i].endMs,
            text: all[i].text
          ),
    ];
  }

  /// 正在原位播这一镜时该显示哪一屏——听到的话和看到的字对上
  String _playingScreenText(int j, int pos) {
    final rows = _screensOfShot(j);
    if (rows.isEmpty) return '';
    final shot = line.shots[j];
    final (start, _) = _shotWindow(j);
    final atMs =
        start + ((pos - shot.trimStartMs) / shot.speed).round();
    for (final r in rows.reversed) {
      if (r.startMs <= atMs) return r.text;
    }
    return rows.first.text;
  }

  /// 这一镜时间窗内的字幕屏列表：一屏一行，看得见、改得动
  Widget _screenList(int j) {
    final rows = _screensOfShot(j);
    final playing = inlineKey == 'shot_${line.id}_$j';
    // 老配音没有逐字时间：屏还是照分（不堆字），但切点改不了——
    // 说清为什么、说清怎么办，不让人对着改不动的界面猜
    final timed = line.voiceover?.words.isNotEmpty ?? false;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('字幕 · ${rows.length} 屏',
              style: const TextStyle(
                  fontSize: AppFontSize.micro,
                  color: AppColors.textSecondary)),
          if (!timed) ...[
            const SizedBox(width: AppSpacing.sm),
            const Tooltip(
              message: '这句配音是早期生成的，没带逐字时间，所以只能按字数把\n时间摊开。重新配一次音就能手工分屏、按播放位置打轴。',
              child: Text('按字数均分',
                  style: TextStyle(
                      fontSize: AppFontSize.micro, color: AppColors.orange)),
            ),
            const SizedBox(width: 6),
            InkWell(
              key: ValueKey('band-fix-timing-$index'),
              onTap: handlers.onFixTimings,
              child: const Text('补上逐字时间',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      fontWeight: FontWeight.w600,
                      color: AppColors.accentBlueLight)),
            ),
          ],
          if (timed && line.subtitleScreens != null) ...[
            const SizedBox(width: AppSpacing.sm),
            const Text('已手改',
                style: TextStyle(
                    fontSize: AppFontSize.micro, color: AppColors.orange)),
            const SizedBox(width: 6),
            InkWell(
              key: ValueKey('band-subtitle-auto-$index'),
              onTap: () => handlers.onScreenReset(index),
              child: const Text('恢复自动',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.accentBlueLight)),
            ),
          ],
          const Spacer(),
          // 打轴：这一镜正在播时，听到该换屏的地方点一下
          if (playing && timed)
            InkWell(
              key: ValueKey('band-subtitle-cut-$index-$j'),
              onTap: () => handlers.onSubtitleCutHere(index, j),
              child: const Text('✂ 在这里换屏',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      fontWeight: FontWeight.w600,
                      color: AppColors.accentBlueLight)),
            ),
        ]),
        const SizedBox(height: 4),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(children: [
              // 界面上的时间一律是成片时间
              SizedBox(
                width: 38,
                child: Text('${(row.startMs / 1000).toStringAsFixed(1)}s',
                    style: const TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.textTertiary,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ),
              Expanded(
                child: !timed
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(row.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: AppFontSize.caption,
                                color: AppColors.textSecondary)),
                      )
                    : _ScreenTextField(
                  key: ValueKey(
                      'band-screen-$index-${row.index}-${row.text.hashCode}'),
                  text: row.text,
                  onChanged: (t) => handlers.onScreenText(index, row.index, t),
                ),
              ),
              // 改不了的行不摆一排灰图标（那看着像坏了）——
              // 出路写在标题行的「补上逐字时间」上
              if (timed) ...[
                _screenAction(
                  key: 'band-screen-split-$index-${row.index}',
                  icon: Icons.content_cut,
                  tip: '从中间拆成两屏',
                  onTap: row.endMs - row.startMs < 400
                      ? null
                      : () => handlers.onScreenCut(
                          index, (row.startMs + row.endMs) ~/ 2),
                ),
                _screenAction(
                  key: 'band-screen-merge-$index-${row.index}',
                  icon: Icons.call_merge,
                  tip: '并回上一屏',
                  onTap: row.index == 0
                      ? null
                      : () => handlers.onScreenMerge(index, row.index),
                ),
                _screenAction(
                  key: 'band-screen-hide-$index-${row.index}',
                  icon: Icons.visibility_off_outlined,
                  tip: '这屏不出字',
                  onTap: () => handlers.onScreenText(index, row.index, ''),
                ),
              ],
            ]),
          ),
      ]),
    );
  }

  /// 屏行尾的一个动作。**能点就得看得见**：常态用二级文字色（比背景
  /// 高出一档），指上去变蓝并浮出底衬——不是那种要贴着屏幕找的灰点
  Widget _screenAction({
    required String key,
    required IconData icon,
    required String tip,
    VoidCallback? onTap,
  }) =>
      Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 400),
        child: _HoverIcon(
          key: ValueKey(key),
          icon: icon,
          onTap: onTap,
        ),
      );

  // ---- 配音行（紧凑）：状态 · 音色 · 时长 · 生成 · 试听 ----

  Widget _voiceRow() {
    final vo = line.voiceover;
    final state = handlers.voiceStateOf(line);
    // 显示**有效值**：行上没设就是本片基调。显示行上的 null 会让跟随
    // 本片的行看起来像是没选过音色
    final effectiveVoice = handlers.voiceIdOf(line);
    final rate = handlers.speechRateOf(line);
    final following = line.voiceId == null && effectiveVoice != null;
    final voiceName = effectiveVoice == null
        ? null
        : (VoiceCatalog.byId(effectiveVoice)?.ref.name ?? effectiveVoice);
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
          for (final (r, label) in const [
            (-25, '语速 0.75x'),
            (0, '语速 1x'),
            (25, '语速 1.25x'),
            (50, '语速 1.5x'),
          ])
            PopupMenuItem(
              value: '$r',
              height: 32,
              child: Row(children: [
                if (rate == r)
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
            '${following ? '（本片）' : ''}'
            '${rate != 0 ? ' · ${1 + rate / 100}x' : ''}',
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
                TextStyle(fontSize: AppFontSize.micro, color: AppColors.orange))
      // 念岔了的配音要在**听到之前**就看得见：结尾卡住反复念那种，
      // 埋在两分钟的片子里很容易漏过去
      else if (line.voiceDefectText != null)
        Flexible(
          child: Tooltip(
            message: '${line.voiceDefectText}。\n点右边「重新生成」重来一次；'
                '还不行就把这句台词拆短一点。',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 11, color: AppColors.red),
              const SizedBox(width: 3),
              Text('这句念岔了',
                  key: ValueKey('band-voice-defect-$index'),
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      fontWeight: FontWeight.w600,
                      color: AppColors.red)),
            ]),
          ),
        ),
      const Spacer(),
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

/// 没在播时的占位位置（避免每次 build 新建 notifier）
final ValueNotifier<int> _noPosition = ValueNotifier<int>(0);

/// 悬停会亮起来的小图标按钮：常态二级文字色，指上去变蓝并浮出底衬。
/// 不可用时压暗但仍看得见形状——「不能点」和「不存在」是两回事
class _HoverIcon extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _HoverIcon({super.key, required this.icon, this.onTap});

  @override
  State<_HoverIcon> createState() => _HoverIconState();
}

class _HoverIconState extends State<_HoverIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          decoration: BoxDecoration(
            color: _hover && enabled ? AppColors.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(widget.icon,
              size: 14,
              color: !enabled
                  ? AppColors.textTertiary.withValues(alpha: 0.5)
                  : (_hover
                      ? AppColors.accentBlueLight
                      : AppColors.textSecondary)),
        ),
      ),
    );
  }
}
