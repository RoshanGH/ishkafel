import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import 'candidate_ranking.dart';
import 'candidate_search_controller.dart';
import 'picking_messages.dart';

/// 台词视图里的一条候选。
///
/// 整体替换换的是「一句台词对应的一段画面」，所以这一层用户先看的是**这条
/// 素材原本在说什么**——只给一格缩略图，他得一条条点开听才知道合不合适。
///
/// 一行 88pt：缩略图 + 台词两行 + 时长/时长差 + 试看/复制/勾选。一屏能看到
/// 六七条，而此前的双列大卡一屏只有两条。
class CandidateRow extends StatelessWidget {
  final CandidateEntry entry;
  final bool selected;

  /// 目标片段时长，用于时长差
  final int targetMs;

  final VoidCallback onTap;
  final VoidCallback onPlay;

  /// 这一层的检索标签，用来标出「命中几个」——排序凭什么把它排前面，
  /// 得让用户看得见
  final List<String> queryTags;

  const CandidateRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.targetMs,
    required this.onTap,
    required this.onPlay,
    this.queryTags = const [],
  });

  static const double height = 88;

  @override
  Widget build(BuildContext context) {
    final material = entry.material;
    return GestureDetector(
      key: Key('picking-candidate-${material.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: height,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.purple.withValues(alpha: 0.12)
              : AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? AppColors.purple : AppColors.border,
            width: selected ? AppStroke.emphasis : AppStroke.hairline,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _thumb(material.thumbnailUrl),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: _texts(context, material)),
            _actions(context, material),
          ],
        ),
      ),
    );
  }

  /// 竖屏素材的小图：42×72，够认出「是不是这段画面」，又不挤掉台词
  Widget _thumb(String? url) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 42,
          height: 72,
          child: url == null || url.isEmpty
              ? _thumbFallback(Icons.image_not_supported_outlined)
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, progress) =>
                      progress == null ? child : _thumbFallback(Icons.hourglass_empty),
                  errorBuilder: (context, error, stack) =>
                      _thumbFallback(Icons.broken_image_outlined),
                ),
        ),
      );

  Widget _thumbFallback(IconData icon) => Container(
        color: AppColors.stageBackground,
        child: Center(child: Icon(icon, size: 14, color: AppColors.textTertiary)),
      );

  Widget _texts(BuildContext context, material) {
    // 没有旁白就退回画面描述——留白等于让用户以为这条素材坏了
    final hasVoiceover = (material.voiceover as String).isNotEmpty;
    final text = hasVoiceover
        ? material.voiceover as String
        : (material.sceneDescription as String);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text.isEmpty ? '（这条素材没有台词，也没有画面描述）' : text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: text.isEmpty ? AppColors.textTertiary : AppColors.textPrimary,
            fontSize: AppFontSize.caption,
            height: 1.4,
          ),
        ),
        const Spacer(),
        Row(
          children: [
            if (!hasVoiceover && text.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Text('画面',
                    style: TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: AppFontSize.micro)),
              ),
            _spec(),
            _match(),
          ],
        ),
      ],
    );
  }

  /// 命中了几个检索标签。写出来排序才解释得通——否则用户只觉得顺序莫名其妙。
  Widget _match() {
    if (queryTags.isEmpty) return const SizedBox.shrink();
    final hit = CandidateRanking.overlap(entry.material.tags, queryTags);
    if (hit == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs),
      child: Text('命中 $hit/${queryTags.length} 标签',
          style: const TextStyle(
              color: AppColors.purple, fontSize: AppFontSize.micro)),
    );
  }

  /// 时长与时长差。探测中给占位；探测失败就不显示——显示 0 会变成一个假徽标。
  Widget _spec() {
    if (entry.probing) {
      return const Text(probingSpecLabel,
          style: TextStyle(
              color: AppColors.textTertiary, fontSize: AppFontSize.micro));
    }
    final spec = entry.spec;
    if (spec == null) return const SizedBox.shrink();
    final delta =
        durationDeltaText(candidateMs: spec.durationMs, targetMs: targetMs);
    return Row(
      children: [
        Text(candidateDurationText(spec.durationMs),
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: AppFontSize.micro)),
        if (delta != null) ...[
          const SizedBox(width: AppSpacing.xs),
          Text(
            delta,
            key: Key('picking-duration-delta-${entry.material.id}'),
            style: TextStyle(
              color: delta.startsWith('+') ? AppColors.orange : AppColors.green,
              fontSize: AppFontSize.micro,
            ),
          ),
        ],
      ],
    );
  }

  Widget _actions(BuildContext context, material) => Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _check(),
          Row(
            children: [
              _iconButton(
                key: Key('picking-copy-name-${material.id}'),
                icon: Icons.content_copy,
                tooltip: '复制素材名',
                onTap: () => _copy(context, material.name as String),
              ),
              _iconButton(
                key: Key('picking-play-${material.id}'),
                icon: Icons.play_circle_outline,
                tooltip: '试看这条素材',
                onTap: onPlay,
              ),
            ],
          ),
        ],
      );

  Widget _iconButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) =>
      Tooltip(
        message: tooltip,
        child: InkWell(
          key: key,
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(icon, size: 15, color: AppColors.textSecondary),
          ),
        ),
      );

  Widget _check() => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? AppColors.purple : Colors.transparent,
          border: Border.all(
              color: selected ? AppColors.purple : AppColors.textTertiary),
        ),
        child: selected
            ? const Icon(Icons.check, size: 12, color: AppColors.textPrimary)
            : null,
      );

  Future<void> _copy(BuildContext context, String name) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: name));
    messenger?.showSnackBar(SnackBar(
      content: Text('已复制素材名：$name'),
      duration: const Duration(seconds: 2),
    ));
  }
}
