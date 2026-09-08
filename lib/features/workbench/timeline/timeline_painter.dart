import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import '../replaced_duration_label.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/features/workbench/timeline/bgm_track.dart';
import 'package:ishkafel/app/theme/app_colors.dart';
import 'package:ishkafel/app/theme/app_spacing.dart';
import 'package:ishkafel/app/theme/app_typography.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'bgm_edge_hit.dart';
import 'thumbs_span.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/text_layout_cache.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';

/// 时间线辅助素材（抽帧胶片条 / 音频波形）的就绪状态。
///
/// 抽帧要跑十几次 ffmpeg 子进程、波形要提取整段 PCM，真机实测进页面后约
/// 2 秒才有内容。此前两条轨在这段时间里是纯空白、失败时也是纯空白——
/// 用户无从判断是在算还是坏了。
enum TimelineMediaStatus {
  loading,
  ready,
  failed,

  /// 没有原片可取（空白任务）。**这一条永远不会变成 ready**，所以不能
  /// 显示「生成中…」——那是个永远转下去的圈
  noSource,
}

/// 时间线绘制器（无状态纯绘制）
///
/// 绘制刻度尺、单元色块轨、镜头子块轨、缩略图轨、波形轨、播放头，共 6 层，
/// 纵向布局数字全部复用 [TimelineTracks]，不另写一套坐标。
///
/// 缩略图的解码（文件 IO + 生成 [ui.Image]）由 [TimelineView] 负责；本类只
/// 接收已解码的 [thumbImages] 列表进行绘制，保证 CustomPainter 无副作用。
class TimelinePainter extends CustomPainter {
  final List<SemanticUnit> units;
  final EditorSelection? selection;

  /// 配乐方案；空方案时配乐轨画一条「还没配乐」的空槽而不是干脆不画——
  /// 不画的话用户根本不知道有这条轨
  final BgmPlan bgm;

  /// 正在框选的配乐区间（镜头下标，含两端）。拖动过程中画高亮预览。
  final ({int from, int to})? bgmSelecting;

  /// 换音色方案。换过的单元在块体底边画一道绿杠。
  final VoicePlan voices;

  /// 当前替换方案（按单元下标对齐）。时间线上要看得见「哪几段已经挑好了
  /// 素材、各挑了几条」——此前这件事只在右栏里可见，回到时间线就断片了。
  final List<UnitReplacement> replacements;

  /// 被整体替换的单元在**成片**里有多长（单元下标 → 毫秒）。
  /// 时间线画的是原片切分、不变形，但要把「这一段成片里变成多长」写出来，
  /// 否则用户不知道成片总长已经变了
  final Map<int, int> composedDurations;

  final TimelineGeometry geometry;
  /// 已解码的抽帧，**下标即时间格**；某格缺失时为 null（画占位而不是错位平铺）
  final List<ui.Image?>? thumbImages;

  /// 这一镜的字幕手改过没有（手改的标一下，人要看得出哪些自己动过）
  final bool Function(int unitIndex, int shotIndex)? subtitleEdited;

  /// 这一镜字幕的头一句，画在轨上当预览
  final String Function(int unitIndex, int shotIndex)? subtitleTextOf;
  final List<double>? waveEnvelope;
  /// 播放头位置——**成片**毫秒（播放器直接给的那个值）
  final int playheadMs;

  /// 抽帧/波形的就绪状态，决定未就绪时画什么占位
  final TimelineMediaStatus mediaStatus;

  /// 文字排版缓存。由 [TimelineView] 持有并跨帧复用——时间线每帧要画几十段
  /// 文字，而它们在两帧之间几乎从不变化（播放头移动不改变任何一段文字）。
  final TextLayoutCache textCache;

  /// 单元色块内标签文字的左右内边距（左右各一份）
  static const _unitLabelPadding = 6.0;

  /// 单元块内两行文字的行距（首行 12px 字号 + 行间呼吸）
  static const _unitLineHeight = 17.0;

  /// 标签窄于这个宽度就不画：只画得下一个省略号，白付文字 layout 的开销
  /// （实测 60 单元 fit 视图下每帧 2.1ms 全花在渲染省略号上）
  static const _minLabelWidth = 24.0;

  /// 换过音色的单元底边那道杠的高度
  static const _voiceMarkH = 3.0;

  /// 单元色块 6 色循环
  static const _unitColors = [
    AppColors.accentBlue,
    AppColors.green,
    AppColors.orange,
    AppColors.red,
    AppColors.purple,
    AppColors.textSecondary,
  ];

  const TimelinePainter({
    required this.units,
    required this.selection,
    required this.geometry,
    this.bgm = BgmPlan.empty,
    this.bgmSelecting,
    this.composedDurations = const {},
    this.voices = VoicePlan.empty,
    this.thumbImages,
    this.subtitleEdited,
    this.subtitleTextOf,
    this.waveEnvelope,
    required this.playheadMs,
    this.replacements = const [],
    this.mediaStatus = TimelineMediaStatus.ready,
    required this.textCache,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintRuler(canvas, size);
    _paintTrackLabels(canvas, size);
    _paintUnitsTrack(canvas, size);
    _paintShotsTrack(canvas, size);
    _paintSubsTrack(canvas, size);
    _paintBgmTrack(canvas, size);
    _paintThumbsTrack(canvas, size);
    _paintWaveTrack(canvas, size);
    _paintPlayhead(canvas, size);
  }

  /// 六条轨的标题条。标题同时是操作说明——「视觉镜头严格嵌套在台词语义
  /// 单元内」是本产品的核心约束，写在轨道上比藏进帮助文档有效得多。
  void _paintTrackLabels(Canvas canvas, Size size) {
    final entries = <(double, String, String)>[
      (TimelineTracks.unitsLabelTop, '台词语义单元', '播放头处拆分；边界在右侧属性面板逐帧调'),
      (TimelineTracks.shotsLabelTop, '视觉镜头', '选中后在播放头处拆分，限制在所属单元内'),
      (
        TimelineTracks.subsLabelTop,
        '字幕',
        '只有换过素材的镜头才烧字幕；选中那一镜可以在右侧改'
      ),
      (
        TimelineTracks.bgmLabelTop,
        '配乐',
        '横向拖选一段连续的台词语义单元；拖两端改长度，点 × 删除'
      ),
      (TimelineTracks.thumbsLabelTop, '画面', ''),
      (TimelineTracks.waveLabelTop, '音频', ''),
    ];
    for (final (top, title, hint) in entries) {
      _drawText(canvas, title, Offset(AppSpacing.xs, top),
          AppColors.textSecondary,
          fontSize: AppFontSize.micro);
      if (hint.isEmpty) continue;
      // 提示文字紧跟标题排布：此前用硬编码偏移，标题文案一变长就会重叠
      final titleWidth = textCache
          .acquire(
              text: title,
              color: AppColors.textSecondary,
              fontSize: AppFontSize.micro)
          .width;
      _drawText(
        canvas,
        '（$hint）',
        Offset(AppSpacing.xs + titleWidth + AppSpacing.sm, top),
        AppColors.textTertiary,
        fontSize: AppFontSize.micro,
      );
    }
  }

  void _paintRuler(Canvas canvas, Size size) {
    final stepMs = geometry.rulerStepMs();
    final linePaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, TimelineTracks.rulerBottom),
      Offset(size.width, TimelineTracks.rulerBottom),
      linePaint,
    );

    // 刻度标的是**成片**时刻：格子按成片长度画，刻度也得按成片走，
    // 否则整体替换之后刻度间距会忽宽忽窄
    final startMs = geometry.pxToComposedMs(0);
    final endMs = geometry.pxToComposedMs(size.width);
    final firstTick = (startMs ~/ stepMs) * stepMs;
    for (var ms = firstTick; ms <= endMs; ms += stepMs) {
      final x = geometry.composedMsToPx(ms);
      if (x < -40 || x > size.width + 40) continue;
      canvas.drawLine(
        Offset(x, TimelineTracks.rulerBottom - 6),
        Offset(x, TimelineTracks.rulerBottom),
        linePaint,
      );
      _drawText(canvas, _formatMs(ms), Offset(x + 2, TimelineTracks.rulerTop),
          AppColors.textSecondary,
          fontSize: AppFontSize.micro);
    }
  }


  /// 这一格在**成片**时间轴上的左右像素。
  ///
  /// **按列表下标问成片轴，绝不拿原片时间去换算。**
  /// `unit.endMs` 是开区间，而「原片毫秒 → 成片毫秒」是按「谁的原片区间盖住
  /// 它」找的——`endMs` 落进的是**相邻那一段**。列表顺序和原片顺序一致时两者
  /// 正好相等，看不出问题；手加的单元被拖到最前之后（它在原片上的占位排在
  /// 末尾），原片里最后那个单元的右边界会被算成手加单元的成片起点 0，
  /// 矩形左右翻转、整格什么都画不出来——镜头轨上还有块，单元轨那儿是空的
  /// （2026-09-08 真机）。
  (double, double) _unitPx(int listIndex) {
    final axis = geometry.axis;
    final unit = units[listIndex];
    if (axis == null) {
      return (geometry.msToPx(unit.startMs), geometry.msToPx(unit.endMs));
    }
    final start = axis.startOf(listIndex);
    return (
      geometry.composedMsToPx(start),
      geometry.composedMsToPx(start + axis.durationOf(listIndex))
    );
  }

  /// 这一镜在**成片**上的左右像素。理由同 [_unitPx]——最后一镜的 `endMs`
  /// 等于所属单元的 `endMs`，一样会翻转
  (double, double) _shotPx(int unitIndex, int shotIndex) {
    final axis = geometry.axis;
    final a = axis?.composedShotStart(unitIndex, shotIndex);
    final b = axis?.composedShotEnd(unitIndex, shotIndex);
    if (a == null || b == null) {
      final shot = units[unitIndex].shots[shotIndex];
      return (geometry.msToPx(shot.startMs), geometry.msToPx(shot.endMs));
    }
    return (geometry.composedMsToPx(a), geometry.composedMsToPx(b));
  }

  /// 整体替换的单元在镜头轨上画成一整块，写明「整段已替换」
  void _paintReplacedShotSpan(Canvas canvas, Size size, int listIndex,
      SemanticUnit unit, Color unitColor) {
    final (left, right) = _unitPx(listIndex);
    if (right < 0 || left > size.width) return;
    final rect = Rect.fromLTRB(left + _shotGap / 2, TimelineTracks.shotsTop,
        right - _shotGap / 2, TimelineTracks.shotsBottom);
    if (rect.width <= 0) return;

    canvas.drawRect(
        rect, Paint()..color = AppColors.purple.withValues(alpha: 0.18));
    canvas.drawRect(
      rect,
      Paint()
        ..color = AppColors.purple.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = AppStroke.hairline,
    );
    final maxWidth = rect.width - _shotLabelPadding * 2;
    if (maxWidth <= 0) return;
    _drawText(
      canvas,
      '整段已替换',
      Offset(rect.left + _shotLabelPadding, rect.top + 4),
      AppColors.purple,
      fontSize: AppFontSize.micro,
      maxWidth: maxWidth,
    );
  }

  String _formatMs(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _paintUnitsTrack(Canvas canvas, Size size) {
    for (var u = 0; u < units.length; u++) {
      final unit = units[u];
      final (left, right) = _unitPx(u);
      if (right < 0 || left > size.width) continue;

      final rect = Rect.fromLTRB(
          left, TimelineTracks.unitsTop, right, TimelineTracks.unitsBottom);
      final color = _unitColors[unit.index % _unitColors.length];
      final selected = selection != null &&
          selection!.shotIndex == null &&
          selection!.unitIndex == unit.index;

      canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.22));
      canvas.drawRect(
        rect,
        Paint()
          ..color = selected
              ? color.withValues(alpha: 1)
              : color.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 2 : 1,
      );

      // 换过音色的单元在底边画一道绿杠。
      //
      // 为什么不像配乐那样单开一条轨：音色本来就属于单元，标在单元块上比
      // 另起一条更贴切；而且第六条轨会把轨道总高推到 332px，反推最小窗口高
      // 972——1440×900 的笔记本就装不下整个窗口了。
      // 整体替换挑了几条，就在块体右上角标几——点它直接跳到右栏那一段
      final wholeCount =
          ReplacementBadges.wholeCount(replacements, unit.index);
      if (wholeCount > 0) {
        _drawBadge(canvas, ReplacementBadges.unitBadgeRect(rect), '$wholeCount');
      }

      if (voices.voiceOf(unit.index) != null) {
        canvas.drawRect(
          Rect.fromLTRB(rect.left, rect.bottom - _voiceMarkH, rect.right,
              rect.bottom),
          Paint()..color = AppColors.green,
        );
      }

      // 块体窄到放不下左右内边距时（拖边界产生的亚像素单元），标签无处可画，
      // 直接跳过：此时 `rect.width - 内边距*2` 为负，交给 TextPainter 会在
      // 绘制中途抛异常，让本帧后续所有绘制丢失（见 [_drawText] 文档）。
      final labelMaxWidth = rect.width - _unitLabelPadding * 2;
      if (labelMaxWidth < _minLabelWidth) continue;

      // 两行信息层级：第一行是定位用的编号与时长（扫读时先找它），
      // 第二行才是台词摘要。挤成一行时编号会被长台词淹没。
      canvas.save();
      canvas.clipRect(rect);
      final textLeft = rect.left + _unitLabelPadding;
      _drawText(
        canvas,
        _unitHeadline(unit),
        Offset(textLeft, rect.top + AppSpacing.xs),
        AppColors.textPrimary,
        fontSize: AppFontSize.body,
        maxWidth: labelMaxWidth,
      );
      _drawText(
        canvas,
        unit.transcript,
        Offset(textLeft, rect.top + AppSpacing.xs + _unitLineHeight),
        AppColors.textSecondary,
        fontSize: AppFontSize.caption,
        maxWidth: labelMaxWidth,
      );
      canvas.restore();
    }
  }

  /// 替换数量徽标：圆角小块 + 数字。放不下就不画——半个徽标比没有更糟。
  void _drawBadge(Canvas canvas, Rect? rect, String text) {
    if (rect == null) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = AppColors.purple,
    );
    final layout = textCache.acquire(
        text: text, color: AppColors.textPrimary, fontSize: AppFontSize.micro);
    layout.paint(
      canvas,
      Offset(rect.center.dx - layout.width / 2,
          rect.center.dy - layout.height / 2),
    );
  }

  /// 单元块首行：编号 + 标签（打标接通后）或时长
  String _unitHeadline(SemanticUnit unit) {
    final id = 'U${unit.index + 1}';
    // 整体替换会改变这一段在成片里的长度——那比标签更要紧，先写它
    final replaced = replacedDurationLabel(
        sourceMs: unit.endMs - unit.startMs,
        composedMs: composedDurations[unit.index]);
    if (replaced != null) return '$id · $replaced';
    if (unit.tags.isNotEmpty) return '$id ${unit.tags.first}';
    final seconds = (unit.endMs - unit.startMs) / 1000;
    return '$id · ${seconds.toStringAsFixed(1)}s';
  }

  /// 相邻镜头块体之间的视觉间隙（左右各内缩一半）
  static const _shotGap = 2.0;

  /// 镜头编号标签的左内边距
  static const _shotLabelPadding = 4.0;

  /// 波形按像素列重采样时每根柱子的宽度。取 2px 而不是 1px：
  /// 1px 柱在 Retina 上会被抗锯齿糊掉，2px 既清晰又足够密。
  static const _waveColumnWidth = 2.0;

  /// 画视觉镜头轨：每个镜头一个独立块体。
  ///
  /// 块体填充沿用**所属台词语义单元的颜色**（低透明度），让"视觉镜头严格
  /// 嵌套在语义单元内"这条核心约束在视觉上一眼可见；选中态改用紫色实心
  /// 高亮，与单元轨的选中态（单元自身色描边加粗）区分开。
  void _paintShotsTrack(Canvas canvas, Size size) {
    for (var u = 0; u < units.length; u++) {
      final unit = units[u];
      final unitColor = _unitColors[unit.index % _unitColors.length];
      // 被整体替换的单元：原来那些视觉镜头在成片里已经不存在了（整段换成了
      // 另一条素材）。还按原样画一排小格子，等于让用户去点一批点不动的东西
      if (geometry.axis?.isReplaced(unit.index) ?? false) {
        _paintReplacedShotSpan(canvas, size, u, unit, unitColor);
        continue;
      }
      for (var s = 0; s < unit.shots.length; s++) {
        final (left, right) = _shotPx(u, s);
        if (right < 0 || left > size.width) continue;

        // 内缩出相邻块体之间的间隙；块体本身比间隙还窄时不再内缩，
        // 否则会得到零宽甚至负宽的矩形
        final inset = (right - left) > _shotGap * 2 ? _shotGap / 2 : 0.0;
        final rect = Rect.fromLTRB(left + inset, TimelineTracks.shotsTop,
            right - inset, TimelineTracks.shotsBottom);

        final selected = selection != null &&
            selection!.shotIndex == s &&
            selection!.unitIndex == unit.index;

        canvas.drawRect(
          rect,
          Paint()
            ..color = selected
                ? AppColors.purple.withValues(alpha: 0.42)
                : unitColor.withValues(alpha: 0.16),
        );
        canvas.drawRect(
          rect,
          Paint()
            ..color = selected
                ? AppColors.purple
                : unitColor.withValues(alpha: 0.5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = selected ? 2 : 1,
        );

        // 镜头替换挑了几条同样标出来
        final shotCount =
            ReplacementBadges.shotCount(replacements, unit.index, s);
        if (shotCount > 0) {
          _drawBadge(
              canvas, ReplacementBadges.shotBadgeRect(rect), '$shotCount');
        }

        // 放不下编号就只留块体（负数 maxWidth 会让整帧绘制中断，见 [_drawText]）
        final labelMaxWidth = rect.width - _shotLabelPadding * 2;
        if (labelMaxWidth <= 0) continue;

        canvas.save();
        canvas.clipRect(rect);
        _drawText(
          canvas,
          'S${s + 1}',
          Offset(rect.left + _shotLabelPadding, rect.top + 6),
          selected ? AppColors.textPrimary : AppColors.textSecondary,
          fontSize: AppFontSize.micro,
          maxWidth: labelMaxWidth,
        );
        canvas.restore();
      }
    }
  }

  /// 配乐轨：每段配乐一个块体，横跨它覆盖的那串镜头（可以跨台词语义单元）。
  ///
  /// 空方案时画一条虚底空槽：干脆不画的话，用户根本不知道有这条轨，
  /// 也就不会想到可以在这里配乐。
  void _paintBgmTrack(Canvas canvas, Size size) {
    final top = TimelineTracks.bgmTop;
    final bottom = TimelineTracks.bgmBottom;

    canvas.drawRect(
      Rect.fromLTRB(0, top, size.width, bottom),
      Paint()..color = AppColors.surfaceCard.withValues(alpha: 0.5),
    );

    // 正在框选：先画预览，让用户看到自己圈到了哪几个**台词语义单元**。
    // 这里曾经拿单元下标去查打平后的镜头，圈一个单元只画出第一个镜头那一
    // 小块——看着就是「拉不动」
    if (bgmSelecting case final sel?) {
      if (units.isNotEmpty) {
        final last = units.length - 1;
        final lo = math.min(sel.from, sel.to).clamp(0, last);
        final hi = math.max(sel.from, sel.to).clamp(0, last);
        final (loLeft, _) = _unitPx(lo);
        final (_, hiRight) = _unitPx(hi);
        final rect = Rect.fromLTRB(loLeft, top, hiRight, bottom);
        canvas.drawRect(
            rect, Paint()..color = AppColors.accentBlue.withValues(alpha: 0.3));
        canvas.drawRect(
          rect,
          Paint()
            ..color = AppColors.accentBlue
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }

    for (final span in bgmSpans(bgm, units)) {
      final left = geometry.msToPx(span.startMs);
      final right = geometry.msToPx(span.endMs);
      if (right < 0 || left > size.width) continue;
      final rect = Rect.fromLTRB(left + 1, top, right - 1, bottom);
      if (rect.width <= 0) continue;

      canvas.drawRect(
          rect, Paint()..color = AppColors.green.withValues(alpha: 0.22));
      canvas.drawRect(
        rect,
        Paint()
          ..color = AppColors.green.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );

      // 徽标在左、删除按钮在右，文字只能用中间剩下的那段——不让开的话
      // 曲名会被压在徽标底下（真机上就这么糊过一次）
      final badge = ReplacementBadges.bgmBadgeRect(rect);
      final showBadge = span.segment.materials.length > 1 && badge != null;
      final showDelete = rect.width >= bgmDeleteMinWidth;
      final textLeft = rect.left +
          _shotLabelPadding +
          (showBadge ? badge.width + ReplacementBadges.inset : 0);
      final textRight = rect.right -
          _shotLabelPadding -
          (showDelete ? bgmDeleteSize + bgmEdgeHitRadius : 0);
      final maxWidth = textRight - textLeft;
      if (maxWidth <= 0) continue;
      canvas.save();
      canvas.clipRect(rect);
      // 名字后面缀一句处理方式：同一首曲子铺在不同长度的区间上，块体长得
      // 一样，不写出来用户没法一眼看出哪段会循环。
      // 「裁」两个字太省，会让人以为素材被改了——其实只是播到段尾就停
      final short = span.segment.fit.shortLabel;
      final fit = short.isEmpty ? '' : ' · $short';
      // 选了几首备选就标几——和 U/S 两层的徽标一个意思：导出时这一段会
      // 轮流用这几首
      if (showBadge) {
        _drawBadge(canvas, badge, '${span.segment.materials.length}');
      }

      // 段落上直接给一个删除按钮：此前删一段要点开素材库浮层再点移除，太重
      if (showDelete) {
        final boxRight = rect.right - bgmEdgeHitRadius;
        final boxTop = rect.top + 2;
        final center =
            Offset(boxRight - bgmDeleteSize / 2, boxTop + bgmDeleteSize / 2);
        canvas.drawCircle(
            center, bgmDeleteSize / 2, Paint()..color = const Color(0x66000000));
        final cross = Paint()
          ..color = AppColors.textPrimary
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round;
        const r = 3.0;
        canvas.drawLine(center.translate(-r, -r), center.translate(r, r), cross);
        canvas.drawLine(center.translate(r, -r), center.translate(-r, r), cross);
      }
      _drawText(
        canvas,
        '${span.segment.previewMaterial.name}$fit',
        Offset(textLeft, rect.top + 5),
        AppColors.textPrimary,
        fontSize: AppFontSize.micro,
        maxWidth: maxWidth,
      );
      canvas.restore();
    }
  }

  /// 字幕轨：**只有换过素材的镜头才有**。
  ///
  /// 没换的镜头字幕烧在原片像素里，我们既读不出也不重渲——那一段留空是
  /// 如实的，画点什么反而让人以为我们管得着。
  ///
  /// 手改过的那几段单独标一下：人得能一眼看出哪些是自己动过的
  void _paintSubsTrack(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
        0, TimelineTracks.subsTop, size.width, TimelineTracks.subsBottom);
    canvas.save();
    canvas.clipRect(rect);
    for (var u = 0; u < units.length; u++) {
      final unit = units[u];
      for (var i = 0; i < unit.shots.length; i++) {
        // 换没换素材直接看替换方案——外面再传一份只会多一处可能对不上
        if (u >= replacements.length) continue;
        if ((replacements[u].shotCandidateIds[i]?.isEmpty ?? true)) continue;
        final (left, right) = _shotPx(u, i);
        if (right < 0 || left > size.width) continue;
        final edited = subtitleEdited?.call(u, i) ?? false;
        final box = Rect.fromLTRB(left + 1, TimelineTracks.subsTop + 2,
            right - 1, TimelineTracks.subsBottom - 2);
        if (box.width <= 0) continue;
        canvas.drawRRect(
          RRect.fromRectAndRadius(box, const Radius.circular(3)),
          Paint()
            ..color = (edited ? AppColors.accentBlue : AppColors.textTertiary)
                .withValues(alpha: edited ? 0.5 : 0.22),
        );
        final label = subtitleTextOf?.call(u, i) ?? '';
        if (label.isEmpty || box.width < 24) continue;
        canvas.save();
        canvas.clipRect(box);
        _drawText(canvas, label, Offset(box.left + 4, box.top + 3),
            AppColors.textPrimary,
            fontSize: AppFontSize.micro, maxWidth: box.width - 8);
        canvas.restore();
      }
    }
    canvas.restore();
  }

  void _paintThumbsTrack(Canvas canvas, Size size) {
    final images = thumbImages;
    if (images == null || images.isEmpty) {
      _paintTrackPlaceholder(canvas, size, TimelineTracks.thumbsTop,
          TimelineTracks.thumbsBottom, '画面缩略图');
      return;
    }

    final trackRect = Rect.fromLTRB(
        0, TimelineTracks.thumbsTop, size.width, TimelineTracks.thumbsBottom);
    canvas.save();
    canvas.clipRect(trackRect);
    // **按原片跨度等分，不是按成片总长**：缩略图是从原片抽的，代表原片
    // 0~原片时长。手动加的单元在原片上不存在，拿成片总长去等分会让整条
    // 胶片条压扁、和上面的单元块全部错位（2026-09-07 真机 bug）。
    // 那一段本来就没有原片画面可放，留空是对的
    final spanMs = sourceSpanMs(units);
    if (spanMs <= 0) {
      canvas.restore();
      return;
    }
    final count = images.length;
    final imagePaint = Paint()..filterQuality = FilterQuality.low;
    for (var i = 0; i < count; i++) {
      final segStartMs = spanMs * i / count;
      final segEndMs = spanMs * (i + 1) / count;
      final left = geometry.msToPx(segStartMs.round());
      final right = geometry.msToPx(segEndMs.round());
      if (right < 0 || left > size.width) continue;

      final dst = Rect.fromLTRB(
          left, TimelineTracks.thumbsTop, right, TimelineTracks.thumbsBottom);
      final image = images[i];
      if (image == null) {
        // 这一格抽帧失败：画灰底而不是让后面的画面顶上来（顶上来等于整条
        // 胶片条与时间轴错位，用户按画面定位切点会一直定错）
        canvas.drawRect(
          dst,
          Paint()..color = AppColors.textTertiary.withValues(alpha: 0.12),
        );
        continue;
      }
      canvas.drawImageRect(image, _coverSrcRect(image, dst), dst, imagePaint);
    }
    canvas.restore();
  }

  /// 按 cover 规则算出源图裁剪区：等比填满目标格，多出的部分居中裁掉。
  ///
  /// 本项目的工作对象是 9:16 竖屏成片，而胶片条格子是宽扁的（约 100×52），
  /// 直接把整张源图拉进目标矩形会横向拉伸约 3.4 倍，人脸全变形——这与
  /// CLAUDE.md「竖屏素材为主要工作对象」的定位直接冲突。
  Rect _coverSrcRect(ui.Image image, Rect dst) {
    final srcW = image.width.toDouble();
    final srcH = image.height.toDouble();
    if (dst.width <= 0 || dst.height <= 0) {
      return Rect.fromLTWH(0, 0, srcW, srcH);
    }
    final dstAspect = dst.width / dst.height;
    final srcAspect = srcW / srcH;
    if (srcAspect > dstAspect) {
      // 源图更宽：保留全高，横向居中裁剪
      final keepW = srcH * dstAspect;
      return Rect.fromLTWH((srcW - keepW) / 2, 0, keepW, srcH);
    }
    // 源图更高（竖屏素材的常态）：保留全宽，纵向居中裁剪
    final keepH = srcW / dstAspect;
    return Rect.fromLTWH(0, (srcH - keepH) / 2, srcW, keepH);
  }

  /// 媒体未就绪时的轨道占位：避免整条轨一片空白被误认为"这栏坏了"。
  /// 加载中与失败给不同的措辞与颜色，让用户能区分「在算」与「算失败了」。
  void _paintTrackPlaceholder(
      Canvas canvas, Size size, double top, double bottom, String what) {
    if (mediaStatus == TimelineMediaStatus.ready) return;
    final rect = Rect.fromLTRB(0, top, size.width, bottom);
    final failed = mediaStatus == TimelineMediaStatus.failed;
    final noSource = mediaStatus == TimelineMediaStatus.noSource;
    canvas.drawRect(
      rect,
      Paint()
        ..color = (failed ? AppColors.red : AppColors.textTertiary)
            .withValues(alpha: noSource ? 0.06 : 0.10),
    );
    _drawText(
      canvas,
      noSource
          ? '这条任务没有原片，$what 这一轨用不上'
          : (failed ? '$what生成失败' : '$what生成中…'),
      Offset(AppSpacing.sm, top + (bottom - top) / 2 - 7),
      failed
          ? AppColors.red
          : (noSource ? AppColors.textTertiary : AppColors.textSecondary),
      fontSize: AppFontSize.caption,
      maxWidth: size.width - AppSpacing.sm * 2,
    );
  }

  void _paintWaveTrack(Canvas canvas, Size size) {
    final envelope = waveEnvelope;
    if (envelope == null || envelope.isEmpty) {
      _paintTrackPlaceholder(canvas, size, TimelineTracks.waveTop,
          TimelineTracks.waveBottom, '音频波形');
      return;
    }

    // 按**可视像素列**重采样，而不是按包络桶逐个画矩形。
    //
    // 按桶画时，柱子的疏密取决于「桶数 ÷ 片长」这个固定值：5 分钟素材放大
    // 20 倍后视口只覆盖 15 秒，里面只落得下约 100 个桶，于是满屏只有 100 根
    // 等高的宽柱——而用户放大波形恰恰是为了看清语句之间的停顿，宽柱内部
    // 没有任何起伏可看。按像素列取该列覆盖时间范围内的包络峰值，柱子密度
    // 就与缩放无关，始终铺满视口。
    final midY = TimelineTracks.waveTop + TimelineTracks.waveH / 2;
    final barPaint =
        Paint()..color = AppColors.accentBlue.withValues(alpha: 0.55);
    final count = envelope.length;
    // **按原片跨度索引包络，不是按成片总长**：波形和胶片条一样是从原片抽的，
    // 手加的单元在原片上不存在，拿成片总长去换算会让整条波形错位
    final durationMs = sourceSpanMs(units);
    if (durationMs <= 0) return;

    for (var x = 0.0; x < size.width; x += _waveColumnWidth) {
      final startMs = geometry.pxToMs(x);
      final endMs = geometry.pxToMs(x + _waveColumnWidth);
      // 落在原片范围之外（手加单元占的那段）：那里本来就没有原片声音
      if (endMs < 0 || startMs > durationMs) continue;

      // 该像素列覆盖的包络下标范围（至少取一个样本，避免高倍放大下取空）
      var from = (count * startMs / durationMs).floor().clamp(0, count - 1);
      var to = (count * endMs / durationMs).ceil().clamp(1, count);
      if (to <= from) to = from + 1;

      var peak = 0.0;
      for (var i = from; i < to; i++) {
        final v = envelope[i];
        if (v > peak) peak = v;
      }

      final halfHeight = peak.clamp(0.0, 1.0) * TimelineTracks.waveH / 2;
      canvas.drawRect(
        Rect.fromLTRB(x, midY - halfHeight, x + _waveColumnWidth, midY + halfHeight),
        barPaint,
      );
    }
  }

  void _paintPlayhead(Canvas canvas, Size size) {
    // 播放头拿的是**成片**位置（播放器就在成片上跑），不走原片映射
    final x = geometry.composedMsToPx(playheadMs);
    if (x < 0 || x > size.width) return;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = AppColors.red
        ..strokeWidth = 2,
    );
  }

  /// 画一行单行省略文字。
  ///
  /// [maxWidth] 一律夹紧到非负：`TextPainter.layout` 内部会执行
  /// `clampDouble(行宽, minWidth = 0, maxWidth)`，而 `clampDouble` 断言
  /// `min <= max`，负数会直接抛 `AssertionError`。该异常发生在
  /// `CustomPainter.paint` 中途，被 `RenderObject._paintWithContext` 吞进
  /// 「rendering library」错误通道，屏幕上的表现是**本帧从抛点起的所有绘制
  /// 全部丢失**——不仅是时间线剩余的镜头/抽帧/波形轨，还包括 `Scaffold` 里
  /// 晚于 body 绘制的顶栏与底部栏（控件仍在树里、布局与命中测试都正常，
  /// 只是画不出来）。因此这里把夹紧放在绘制边界上兜底，调用方另有各自的
  /// 「放不下就不画」判断。
  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color, {
    double fontSize = AppFontSize.body,
    double? maxWidth,
  }) {
    textCache
        .acquire(
            text: text, color: color, fontSize: fontSize, maxWidth: maxWidth)
        .paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant TimelinePainter oldDelegate) {
    return oldDelegate.units != units ||
        oldDelegate.selection != selection ||
        oldDelegate.geometry != geometry ||
        oldDelegate.mediaStatus != mediaStatus ||
        oldDelegate.thumbImages != thumbImages ||
        oldDelegate.waveEnvelope != waveEnvelope ||
        oldDelegate.playheadMs != playheadMs ||
        oldDelegate.bgm != bgm ||
        oldDelegate.bgmSelecting != bgmSelecting ||
        oldDelegate.voices != voices ||
        !const DeepCollectionEquality()
            .equals(oldDelegate.replacements, replacements);
  }
}

/// 替换数量徽标画在哪。painter 与命中测试共用同一份几何——两边各算一次，
/// 迟早会错开，用户点得到的位置和看到的位置不一样。
class ReplacementBadges {
  ReplacementBadges._();

  /// 这个单元整体替换挑了几条；没挑或不是整体替换返回 0
  static int wholeCount(List<UnitReplacement> replacements, int unitIndex) {
    if (unitIndex < 0 || unitIndex >= replacements.length) return 0;
    final r = replacements[unitIndex];
    return r.mode == ReplacementMode.whole ? r.wholeCandidateIds.length : 0;
  }

  /// 这个镜头挑了几条
  static int shotCount(
      List<UnitReplacement> replacements, int unitIndex, int shotIndex) {
    if (unitIndex < 0 || unitIndex >= replacements.length) return 0;
    final r = replacements[unitIndex];
    if (r.mode != ReplacementMode.perShot) return 0;
    return r.shotCandidateIds[shotIndex]?.length ?? 0;
  }

  static const double width = 20;
  static const double height = 14;
  static const double inset = 4;

  /// 单元块右上角。块体窄到放不下徽标时返回 null（半个徽标比没有更糟）
  static Rect? unitBadgeRect(Rect block) {
    if (block.width < width + inset * 2) return null;
    return Rect.fromLTWH(block.right - width - inset, block.top + inset, width,
        height);
  }

  /// 配乐段的备选数量徽标画在**左上角**——右上角让给删除按钮。
  /// 两个挤在一起的话，想删的时候多半点到徽标上
  static Rect? bgmBadgeRect(Rect block) {
    if (block.width < width + inset * 2 + bgmDeleteSize) return null;
    return Rect.fromLTWH(
        block.left + inset, block.top + inset, width, height);
  }

  /// 镜头块右上角。镜头块通常更窄，徽标也更小
  static Rect? shotBadgeRect(Rect block) {
    if (block.width < width + inset) return null;
    return Rect.fromLTWH(
        block.right - width - 2, block.top + 2, width, height);
  }
}
