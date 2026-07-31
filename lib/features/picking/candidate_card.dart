import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import 'candidate_search_controller.dart';
import 'picking_messages.dart';

/// 候选素材卡：缩略图 + 来源名 + 时长/时长差徽标 + 勾选圈。
///
/// 三条硬约束：
/// - 缩略图是**远程 URL**：必须有加载占位与失败兜底，绝不能在 build 里做同步
///   IO，也不能失败后留一块黑；
/// - 规格（时长/分辨率）是异步探测出来的，未完成时显示「探测中」占位而不是
///   空白，探测失败则**不显示**时长差徽标（显示 0 会变成一个"差 100%"的假徽标）；
/// - 勾选是多选，点一下切换。
class CandidateCard extends StatelessWidget {
  final CandidateEntry entry;
  final bool selected;

  /// 目标片段时长（当前视觉镜头或整个台词语义单元），用于算时长差
  final int targetMs;

  final VoidCallback onTap;

  const CandidateCard({
    super.key,
    required this.entry,
    required this.selected,
    required this.targetMs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final material = entry.material;
    return GestureDetector(
      key: Key('picking-candidate-${material.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.stageBackground,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? AppColors.purple : AppColors.border,
            width: selected ? AppStroke.emphasis : AppStroke.hairline,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _thumbnail(material.thumbnailUrl),
            _topRow(material.name),
            _bottomBadge(),
            _checkMark(),
          ],
        ),
      ),
    );
  }

  /// 远程缩略图：加载中给占位、失败给可辨认的兜底图标（都不阻塞 build）
  Widget _thumbnail(String? url) {
    if (url == null || url.isEmpty) return _thumbFallback(Icons.image_not_supported_outlined);
    return Image.network(
      url,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : _thumbFallback(Icons.hourglass_empty),
      errorBuilder: (context, error, stack) =>
          _thumbFallback(Icons.broken_image_outlined),
    );
  }

  Widget _thumbFallback(IconData icon) => Container(
        color: AppColors.surfaceCard,
        child: Center(
            child: Icon(icon, size: 20, color: AppColors.textTertiary)),
      );

  Widget _topRow(String name) => Positioned(
        left: AppSpacing.sm,
        top: AppSpacing.sm,
        right: AppSpacing.xl,
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: AppFontSize.micro,
            shadows: [Shadow(color: AppColors.stageBackground, blurRadius: 3)],
          ),
        ),
      );

  /// 时长与时长差。探测中显示占位；探测失败则连时长都没有——此时不显示徽标，
  /// 用户仍可凭画面与标签挑选。
  Widget _bottomBadge() {
    if (entry.probing) return _pill(const Text(probingSpecLabel, style: _pillStyle));
    final spec = entry.spec;
    if (spec == null) return const SizedBox.shrink();
    final delta = durationDeltaText(candidateMs: spec.durationMs, targetMs: targetMs);
    return _pill(Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(candidateDurationText(spec.durationMs), style: _pillStyle),
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
    ));
  }

  static const _pillStyle = TextStyle(
      color: AppColors.textPrimary, fontSize: AppFontSize.micro);

  Widget _pill(Widget child) => Positioned(
        left: AppSpacing.sm,
        bottom: AppSpacing.sm,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.stageBackground.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(999),
          ),
          child: child,
        ),
      );

  Widget _checkMark() => Positioned(
        right: AppSpacing.sm,
        top: AppSpacing.sm,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? AppColors.purple : Colors.black45,
            border: Border.all(
                color: selected ? AppColors.purple : AppColors.textSecondary),
          ),
          child: selected
              ? const Icon(Icons.check, size: 12, color: AppColors.textPrimary)
              : null,
        ),
      );
}
