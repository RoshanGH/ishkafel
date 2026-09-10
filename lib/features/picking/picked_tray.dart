
import 'package:flutter/material.dart';

import '../shared/thumb_image.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/replacement/brand_consistency.dart';
import 'burned_text_warning.dart';
import 'picked_media_cache.dart';
import 'picking_messages.dart';
import 'picking_widgets.dart';

/// 托盘里的一条：已经勾选的候选。
///
/// [material] 为 null 表示落地记录还没写好（刚勾上、首帧图还在下）——
/// 那也要占一个位置，不能凭空少一条，用户是按「我选了 3 条」来核对的。
@immutable
class PickedItem {
  final int candidateId;
  final PickedMaterial? material;

  /// 是不是这一段的预览版（播放时放的就是它）
  final bool isPreview;

  /// 这一段的目标时长，用来算时长差与倍速；为 0 表示不显示
  final int targetMs;

  /// 这一层的候选会不会整条变速铺满坑位（视觉镜头替换）。
  /// 为真时标倍速——托盘是「我到底选了些什么」的最后一眼
  final bool speedFitToSlot;

  /// 素材本体在本地的状态。用户要能一眼看出「这条已经拿到手了」——
  /// 后台默默下载但状态不可见，只会在导出那一刻被打脸
  final PickedMediaStatus media;

  /// 下不下来的原因（可直接展示）；没失败时为 null
  final String? mediaFailure;

  const PickedItem({
    required this.candidateId,
    this.material,
    this.isPreview = false,
    this.targetMs = 0,
    this.speedFitToSlot = false,
    this.media = PickedMediaStatus.absent,
    this.mediaFailure,
  });
}

/// 「已选」托盘：当前作用域勾了哪几条，一直摆在候选区最上面。
///
/// **为什么必须有**：勾选状态本来只画在候选卡上，而候选卡只有当前这一页的
/// 检索结果。换个检索方式、翻一页、甚至换个项目组之后，选过的那几条根本
/// 不在结果里，界面上一个勾都看不到——用户原话「我没有看到我选了那 3 个，
/// 我不知道是不是我那 3 个」。托盘直接按 id 把素材取回来画出来，
/// 和检索结果是什么完全无关。
class PickedTray extends StatelessWidget {
  final List<PickedItem> items;

  /// 取消勾选
  final ValueChanged<int> onRemove;

  /// 重新下载一条下失败的素材
  final ValueChanged<int>? onRetryMedia;

  /// 这台机器上到底做不做本地固定。不做的时候别说「已存到本地」——
  /// 那是一句没有依据的承诺
  final bool mediaTracked;

  /// 设为预览版
  final ValueChanged<int> onSetPreview;

  /// 原片里露出的产品是什么牌子（[sourceBrandOf] 算出来的）。
  ///
  /// 光看「候选之间打不打架」有个缺口：一条片子的候选全是若也（而原片是
  /// 滴露）时候选之间毫无冲突，可整条都错了。null = 说不出来（老任务
  /// 打标那会儿还没记品牌），那时只靠候选之间那一条判据。
  final String? sourceBrand;

  /// **整条片子**挑的全部素材（不只是当前作用域的 [items]）。
  ///
  /// 品牌冲突是整条片子的事：U1 挑滴露、U3 挑若也，站在 U1 的托盘上看
  /// 只有一个牌子——按当前作用域算就永远不报警，而那正是真实的出错方式，
  /// 人是一个单元一个单元挑下来的。
  final List<PickedMaterial> allPicked;

  const PickedTray({
    super.key,
    required this.items,
    required this.onRemove,
    required this.onSetPreview,
    this.allPicked = const [],
    this.sourceBrand,
    this.onRetryMedia,
    this.mediaTracked = false,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    // 小结和胶囊挤在同一行：右栏的高度全是候选区的本钱，一行说明文字
    // 就是小半张预览图
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Tooltip(
            message: _detail(),
            child: Text(
              '已选 ${items.length}',
              style: const TextStyle(
                  color: AppColors.textTertiary, fontSize: AppFontSize.micro),
            ),
          ),
          for (final item in items) _chip(item),
        ],
      ),
    );
  }

  Widget _chip(PickedItem item) => Container(
        key: Key('picked-chip-${item.candidateId}'),
        width: 220,
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: AppColors.purple.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.purple.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            _thumb(item),
            const SizedBox(width: AppSpacing.xs),
            if (mediaTracked) _mediaDot(item),
            ?_burnedWarning(item),
            ?_brandWarning(item),
            Expanded(
              child: Text(
                _label(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: item.material == null
                      ? AppColors.textTertiary
                      : AppColors.textPrimary,
                  fontSize: AppFontSize.micro,
                ),
              ),
            ),
            _duration(item),
            _icon(
              key: Key('picked-preview-${item.candidateId}'),
              icon: item.isPreview ? Icons.star : Icons.star_border,
              color: item.isPreview ? AppColors.orange : null,
              tooltip: item.isPreview ? '预览播的就是这一条' : '设为预览版',
              onTap: () => onSetPreview(item.candidateId),
            ),
            if (item.media == PickedMediaStatus.failed && onRetryMedia != null)
              _icon(
                key: Key('picked-retry-${item.candidateId}'),
                icon: Icons.refresh,
                color: AppColors.accentBlue,
                tooltip: item.mediaFailure ?? '重新下载',
                onTap: () => onRetryMedia!(item.candidateId),
              ),
            _icon(
              key: Key('picked-remove-${item.candidateId}'),
              icon: Icons.close,
              tooltip: '取消选择',
              onTap: () => onRemove(item.candidateId),
            ),
          ],
        ),
      );

  /// 悬停才看的详情：素材落地到什么程度、★ 是干什么的。
  /// 这些第一次看有用，之后就是噪音，不该常驻在眼前
  String _detail() {
    final plain = items.length > 1
        ? '已选 ${items.length} 条 · ★ 的那条用于预览，导出时每条各出一版'
        : '已选 1 条';
    if (!mediaTracked) return plain;
    final pending = items
        .where((i) => i.media != PickedMediaStatus.ready)
        .length;
    final failed =
        items.where((i) => i.media == PickedMediaStatus.failed).length;
    if (failed > 0) {
      return '已选 ${items.length} 条 · $failed 条素材没下下来，'
          '点 ↻ 重试；不解决的话导出会直接失败';
    }
    if (pending > 0) {
      return '已选 ${items.length} 条 · 正在把素材存到本地（$pending 条待完成）';
    }
    return items.length > 1
        ? '已选 ${items.length} 条 · 素材已全部存到本地 · '
            '★ 的那条用于预览，导出时每条各出一版'
        : '已选 1 条 · 素材已存到本地';
  }

  /// 素材本体的状态点。做成小圆点而不是一行字：一条 260 宽的胶囊放不下
  /// 一句话，而用户扫的是「有没有红的」
  Widget _mediaDot(PickedItem item) {
    final (color, tip) = switch (item.media) {
      PickedMediaStatus.ready => (AppColors.green, '素材已存到本地，'
          '素材库那边被删也不影响这条任务'),
      PickedMediaStatus.downloading => (AppColors.accentBlue, '正在下载素材…'),
      PickedMediaStatus.failed => (
          AppColors.red,
          item.mediaFailure ?? '素材没下下来'
        ),
      PickedMediaStatus.absent => (AppColors.textTertiary, '素材还没开始下'),
    };
    return Tooltip(
      message: tip,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Container(
          key: Key('picked-media-${item.candidateId}'),
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }

  /// 素材名/台词都没有时退回 id——总比一片空白强，用户至少能拿它去库里对
  /// 素材画面上本来就烧着字：换上它之后我们还要再烧一行台词字幕，
  /// 两层字叠在一起，片子就废了。这一条必须在**挑选现场**看得见，
  /// 等到导出才说就晚了
  Widget? _burnedWarning(PickedItem item) {
    final text = burnedTextWarning(item.material);
    if (text == null) return null;
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Tooltip(
        message: text,
        child: Icon(
          key: Key('burned-warn-${item.candidateId}'),
          Icons.subtitles_off,
          size: 13,
          color: AppColors.orange,
        ),
      ),
    );
  }

  /// 这条片子挑的素材里出现了不止一个品牌。
  ///
  /// **按整条片子算，不是按当前这一屏**：单看一条素材判不出品牌错位
  /// （一条片子全用若也的素材没问题，问题是两个牌子同时出现）；
  /// 只看当前作用域同样判不出——人是一个单元一个单元挑下来的，
  /// 每一屏里都只有一个牌子，错位只在合起来看时才现形
  List<PickedMaterial> get _all =>
      allPicked.isEmpty ? [for (final i in items) ?i.material] : allPicked;

  bool get _brandsClash =>
      brandConflict(_all) != null ||
      brandMismatchNotice(picked: _all, sourceBrand: sourceBrand) != null;

  /// 产品露出镜头**不能跨品牌换**：台词说「滴露新款消毒液」而画面是若也
  /// 洗发水直播间，片子自己打自己的脸。真机上交付过这样一条成片
  Widget? _brandWarning(PickedItem item) {
    if (!_brandsClash) return null;
    final text = brandWarning(item.material, conflicting: true);
    if (text == null) return null;
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Tooltip(
        message: text,
        child: Icon(
          key: Key('brand-warn-${item.candidateId}'),
          Icons.storefront,
          size: 13,
          color: AppColors.red,
        ),
      ),
    );
  }

  static String _label(PickedItem item) {
    final material = item.material;
    if (material == null) return '素材 #${item.candidateId}（读取中…）';
    final label = material.label;
    return label.isEmpty ? '素材 #${item.candidateId}' : label;
  }

  /// 变速那一层标倍速，不变速那一层标时长差。探不出时长就只给时长——
  /// 显示 0 会变成一个假徽标
  Widget _duration(PickedItem item) {
    final ms = item.material?.durationMs;
    if (ms == null || ms <= 0) return const SizedBox.shrink();
    final delta = item.targetMs <= 0
        ? null
        : item.speedFitToSlot
            ? candidateSpeedText(candidateMs: ms, slotMs: item.targetMs)
            : durationDeltaText(candidateMs: ms, targetMs: item.targetMs);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        delta ?? candidateDurationText(ms),
        style: TextStyle(
          color: delta == null
              ? AppColors.textTertiary
              : item.speedFitToSlot
                  ? speedBadgeColor(candidateSpeedSeverity(
                      candidateMs: ms, slotMs: item.targetMs))
                  : (delta.startsWith('+')
                      ? AppColors.orange
                      : AppColors.green),
          fontSize: AppFontSize.micro,
        ),
      ),
    );
  }

  /// 首帧图读的是**本地文件**，不是素材库那个一天就过期的签名地址
  Widget _thumb(PickedItem item) {
    final path = item.material?.thumbPath;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: SizedBox(
        width: 13,
        height: 22,
        child: path == null || path.isEmpty
            ? Container(color: AppColors.stageBackground)
            : ThumbImage(
                path: path,
                width: 13,
                errorBuilder: (_) =>
                    Container(color: AppColors.stageBackground)),
      ),
    );
  }

  Widget _icon({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
  }) =>
      Tooltip(
        message: tooltip,
        child: InkWell(
          key: key,
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.xs),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(icon, size: 14, color: color ?? AppColors.textSecondary),
          ),
        ),
      );
}
