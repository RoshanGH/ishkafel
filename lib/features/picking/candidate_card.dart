import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import 'candidate_ranking.dart';
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
///
/// 素材名可复制：卡片只有一行位置，名字长了必然截断，而用户要拿这个名字回
/// miaoa 里查。悬停看全名（Tooltip），点右边那个小图标复制。
class CandidateCard extends StatelessWidget {
  final CandidateEntry entry;
  final bool selected;

  /// 目标片段时长（当前视觉镜头或整个台词语义单元），用于算时长差
  final int targetMs;

  final VoidCallback onTap;

  /// 试看这条素材。静止的一帧几乎分不出差别，而替换进成片的是这段画面在动
  /// 的三秒。
  final VoidCallback onPlay;

  /// 这一层的检索标签，用来标出命中了哪几个。
  ///
  /// 只给个数判断不了像不像——同样「命中 2 个」，是「灶台+实拍」还是
  /// 「实拍+剧情」，这条素材能不能用差别很大。
  final List<String> queryTags;

  const CandidateCard({
    super.key,
    required this.entry,
    required this.selected,
    required this.targetMs,
    required this.onTap,
    required this.onPlay,
    this.queryTags = const [],
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
            _topRow(context, material.id, material.name),
            _bottomBadge(),
            _checkMark(),
            _playButton(),
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

  Widget _topRow(BuildContext context, int id, String name) => Positioned(
        left: AppSpacing.sm,
        top: AppSpacing.sm,
        right: AppSpacing.xl,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              // 名字必然被截断，悬停能看全名——不然只能靠猜
              child: Tooltip(
                message: name,
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: AppFontSize.micro,
                    shadows: [
                      Shadow(color: AppColors.stageBackground, blurRadius: 3)
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 2),
            _copyButton(context, id, name),
          ],
        ),
      );

  /// 复制素材名。用户要拿这个名字回 miaoa 里查，卡片上又必然是截断的。
  Widget _copyButton(BuildContext context, int id, String name) => Tooltip(
        message: '复制素材名',
        child: InkWell(
          key: Key('picking-copy-name-$id'),
          onTap: () => _copy(context, name),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              Icons.content_copy,
              size: 11,
              color: AppColors.textSecondary,
              shadows: const [
                Shadow(color: AppColors.stageBackground, blurRadius: 3)
              ],
            ),
          ),
        ),
      );

  Future<void> _copy(BuildContext context, String name) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: name));
    // 复制这种「什么都没发生」的操作必须有反馈，否则用户会连点好几次
    messenger?.showSnackBar(SnackBar(
      content: Text('已复制素材名：$name'),
      duration: const Duration(seconds: 2),
    ));
  }

  /// 时长与时长差。探测中显示占位；探测失败则连时长都没有——此时不显示徽标，
  /// 用户仍可凭画面与标签挑选。
  Widget _bottomBadge() {
    if (entry.probing) return _pill(const Text(probingSpecLabel, style: _pillStyle));
    final spec = entry.spec;
    final delta = spec == null
        ? null
        : durationDeltaText(candidateMs: spec.durationMs, targetMs: targetMs);
    final hits = CandidateRanking.matchedTags(
        materialTags: entry.material.tags, queryTags: queryTags);
    if (spec == null && hits.isEmpty) return const SizedBox.shrink();

    return _pill(Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (spec != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(candidateDurationText(spec.durationMs), style: _pillStyle),
              if (delta != null) ...[
                const SizedBox(width: AppSpacing.xs),
                Text(
                  delta,
                  key: Key('picking-duration-delta-${entry.material.id}'),
                  style: TextStyle(
                    color:
                        delta.startsWith('+') ? AppColors.orange : AppColors.green,
                    fontSize: AppFontSize.micro,
                  ),
                ),
              ],
            ],
          ),
        // 命中了哪几个标签。格子只有 112pt 宽，放不下就省略，
        // 悬停能看到全部——省略掉的部分不能就此消失
        if (hits.isNotEmpty)
          Tooltip(
            message: '命中 ${hits.length}/${queryTags.length} 个标签：'
                '${hits.join('、')}',
            child: Text(
              '${hits.length}/${queryTags.length} ${hits.join('·')}',
              key: Key('picking-hits-${entry.material.id}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.purple, fontSize: AppFontSize.micro),
            ),
          ),
      ],
    ));
  }

  static const _pillStyle = TextStyle(
      color: AppColors.textPrimary, fontSize: AppFontSize.micro);

  Widget _pill(Widget child) => Positioned(
        left: AppSpacing.sm,
        right: AppSpacing.sm,
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

  /// 试看按钮摆在右下角：左下是时长徽标，右上是勾选圈，这里是唯一不打架的位置
  Widget _playButton() => Positioned(
        right: AppSpacing.sm,
        bottom: AppSpacing.sm,
        child: Tooltip(
          message: '试看这条素材',
          child: InkWell(
            key: Key('picking-play-${entry.material.id}'),
            onTap: onPlay,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: AppColors.stageBackground.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.play_arrow,
                  size: 14, color: AppColors.textPrimary),
            ),
          ),
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
