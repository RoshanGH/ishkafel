import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// 替换裂变的一步
class WorkflowStep {
  final IconData icon;
  final String title;
  final String detail;

  /// 大致耗时，说不准的就写清「取决于什么」，不给假数字
  final String cost;

  const WorkflowStep({
    required this.icon,
    required this.title,
    required this.detail,
    required this.cost,
  });
}

/// 产品一句话。首页、使用说明、关于三处共用，措辞不会各说各的。
const String productTagline = '把一条成片裂变成多条变体：台词与配音不变，只换画面。';

/// 四步流程。术语按 docs/术语表.md，不自造说法——界面上叫「分镜」、
/// 文档里叫「视觉镜头」，用户会以为是两个东西。
const List<WorkflowStep> workflowSteps = [
  WorkflowStep(
    icon: Icons.movie_outlined,
    title: '导入成片',
    detail: '选一条成片，再选两个标签组（分别用于台词语义单元与视觉镜头打标）。',
    cost: '一两分钟',
  ),
  WorkflowStep(
    icon: Icons.auto_awesome_outlined,
    title: '自动分析',
    detail: '转写台词 → 按语义切成台词语义单元 → 单元内按画面切换切成视觉镜头 → 两层打标。',
    cost: '数分钟，镜头越多越久',
  ),
  WorkflowStep(
    icon: Icons.content_cut,
    title: '确认切分',
    detail: '在时间线上逐帧微调两层边界，确认后进入选材。',
    cost: '几分钟',
  ),
  WorkflowStep(
    icon: Icons.grid_view_outlined,
    title: '替换选材与矩阵导出',
    detail: '按相同标签检索候选素材，逐个单元挑选画面，最后按组合批量导出。',
    cost: '取决于挑多少条',
  ),
];

/// 四步流程条。首页与使用说明共用一份，改文案不会漏掉一处。
class WorkflowStepsStrip extends StatelessWidget {
  /// 紧凑排版（首页横向一行）；false 时纵向铺开，适合说明弹窗
  final bool horizontal;

  const WorkflowStepsStrip({super.key, this.horizontal = true});

  @override
  Widget build(BuildContext context) {
    if (!horizontal) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < workflowSteps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: _StepRow(index: i, step: workflowSteps[i]),
            ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < workflowSteps.length; i++) ...[
          if (i > 0) const _Arrow(),
          Expanded(child: _StepColumn(index: i, step: workflowSteps[i])),
        ],
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(top: AppSpacing.md),
        child: Icon(Icons.arrow_forward,
            size: 14, color: AppColors.textTertiary),
      );
}

class _StepColumn extends StatelessWidget {
  final int index;
  final WorkflowStep step;

  const _StepColumn({required this.index, required this.step});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StepBadge(index: index),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(step.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: AppFontSize.emphasis,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(step.detail,
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  height: 1.6,
                  color: AppColors.textSecondary)),
          const SizedBox(height: AppSpacing.xs),
          Text(step.cost,
              style: const TextStyle(
                  fontSize: AppFontSize.micro, color: AppColors.textTertiary)),
        ],
      );
}

class _StepRow extends StatelessWidget {
  final int index;
  final WorkflowStep step;

  const _StepRow({required this.index, required this.step});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepBadge(index: index),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${step.title}　·　${step.cost}',
                    style: const TextStyle(
                        fontSize: AppFontSize.emphasis,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                const SizedBox(height: AppSpacing.xs),
                Text(step.detail,
                    style: const TextStyle(
                        fontSize: AppFontSize.body,
                        height: 1.6,
                        color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      );
}

class _StepBadge extends StatelessWidget {
  final int index;

  const _StepBadge({required this.index});

  @override
  Widget build(BuildContext context) => Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.accentBlue.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Text('${index + 1}',
            style: const TextStyle(
                fontSize: AppFontSize.caption,
                fontWeight: FontWeight.w700,
                color: AppColors.accentBlueLight)),
      );
}
