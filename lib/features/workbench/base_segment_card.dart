import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/editing/base_pin_ops.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/replacement/replacement_plan.dart';
import '../../core/replacement/unit_base.dart';
import 'inspector_widgets.dart';

/// 属性面板里的「这一段的底片」卡片。
///
/// 它回答两件事：**这一段的画面现在取自谁**，以及**能不能把它切成镜头再精修**。
/// 挑了素材的插入段本来只能整条塞进去，切分之后就能一刀一刀换——这是
/// 「替换裂变」在插入段上缺的那半条能力
/// （见 `docs/superpowers/specs/2026-09-14-底片-design.md`）。
class BaseSegmentCard extends StatelessWidget {
  final SemanticUnit unit;
  final UnitReplacement replacement;

  /// 底片那条素材叫什么（取不到时显示 id）
  final String? materialName;

  /// 正在切这一段。切分要跑 ffmpeg 加云端复核，得让人看见在动
  final bool segmenting;

  /// 点「切分这一段」。null = 只读
  final VoidCallback? onSegment;

  /// 点「换一张底片」。null = 只读或还没固定过
  final VoidCallback? onUnpin;

  const BaseSegmentCard({
    super.key,
    required this.unit,
    required this.replacement,
    this.materialName,
    this.segmenting = false,
    this.onSegment,
    this.onUnpin,
  });

  @override
  Widget build(BuildContext context) {
    final choice = baseChoiceOf(unit: unit, replacement: replacement);
    // 底片就是原片的段落不摆这张卡：它的分镜在分析时已经切好了，
    // 多一张只说「用的是原片」的卡片是噪音
    if (choice is OriginalBase) return const SizedBox.shrink();

    final pinned = hasOwnBaseShots(unit);
    final blocked = BasePinOps.segmentBlockedReason(
        unit: unit, replacement: replacement);

    return Padding(
      key: const Key('base-segment-card'),
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          inspectorTitle('这一段的底片'),
          const SizedBox(height: 8),
          inspectorCard([
            inspectorInfoRow('画面取自', _whereFrom(choice)),
            if (pinned) inspectorInfoRow('切出镜头', '${unit.shots.length} 个'),
            const SizedBox(height: 8),
            _hint(pinned, blocked),
            const SizedBox(height: 10),
            _buttons(pinned, blocked),
          ]),
        ],
      ),
    );
  }

  String _whereFrom(BaseChoice choice) => switch (choice) {
        MaterialBase(:final candidateId) =>
          materialName ?? '素材 $candidateId',
        OriginalBase() => '原片这一段',
        NoBase() => '还没挑素材',
      };

  Widget _hint(bool pinned, String? blocked) {
    final text = pinned
        ? '这一段的镜头是按这张底片切出来的，每一镜都能单独换素材。'
            '换一张底片会把已挑的镜头替换全部清掉。'
        : blocked ??
            '切分之后这一段就能一刀一刀地换。'
                '注意：这一段从此只能用这一条素材，其余候选会取消选中。';
    return Text(
      text,
      key: const Key('base-segment-hint'),
      style: const TextStyle(
        fontSize: AppFontSize.caption,
        color: AppColors.textSecondary,
        height: 1.5,
      ),
    );
  }

  Widget _buttons(bool pinned, String? blocked) {
    if (segmenting) {
      return const Row(
        key: Key('base-segmenting'),
        children: [
          SizedBox(
              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('正在看这条素材是怎么切的…',
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textSecondary)),
        ],
      );
    }
    return Row(
      children: [
        FilledButton(
          key: const Key('base-segment-button'),
          onPressed: blocked == null ? onSegment : null,
          child: Text(pinned ? '重新切分' : '切分这一段'),
        ),
        if (pinned) ...[
          const SizedBox(width: 8),
          TextButton(
            key: const Key('base-unpin-button'),
            onPressed: onUnpin,
            child: const Text('换一张底片'),
          ),
        ],
      ],
    );
  }
}
