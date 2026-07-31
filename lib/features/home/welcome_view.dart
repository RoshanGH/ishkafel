import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import 'help_sheet.dart';
import 'readiness.dart';
import 'workflow_steps.dart';

/// 首屏（还没有任何任务时）。
///
/// 这是产品的门面：本应用靠「把 .app 交给同事双击打开」分发，没有安装向导、
/// 没有培训。原来这里只有一行灰字「还没有任务，点击右上角新建任务导入一条
/// 成片」——既不说这是什么，也不说要先准备什么。
class WelcomeView extends StatelessWidget {
  final Readiness readiness;
  final VoidCallback onStart;
  final VoidCallback onOpenSettings;

  const WelcomeView({
    super.key,
    required this.readiness,
    required this.onStart,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl, vertical: AppSpacing.xxl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Masthead(),
                const SizedBox(height: AppSpacing.xxl),
                const WorkflowStepsStrip(),
                const SizedBox(height: AppSpacing.xxl),
                _Actions(
                  readiness: readiness,
                  onStart: onStart,
                ),
                const SizedBox(height: AppSpacing.xl),
                _ReadinessPanel(
                    readiness: readiness, onOpenSettings: onOpenSettings),
              ],
            ),
          ),
        ),
      );
}

class _Masthead extends StatelessWidget {
  const _Masthead();

  @override
  Widget build(BuildContext context) => Column(
        children: [
          const Text('ishkafel',
              style: TextStyle(
                  fontSize: AppFontSize.display,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: AppColors.textPrimary)),
          const SizedBox(height: AppSpacing.sm),
          Text(productTagline,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: AppFontSize.emphasis,
                  height: 1.6,
                  color: AppColors.textSecondary)),
        ],
      );
}

class _Actions extends StatelessWidget {
  final Readiness readiness;
  final VoidCallback onStart;

  const _Actions({required this.readiness, required this.onStart});

  @override
  Widget build(BuildContext context) {
    final blocked = readiness.blockingReason;
    return Column(
      children: [
        FilledButton.icon(
          key: const Key('welcome-start'),
          // 缺 ffmpeg 时点了也只会在中途失败，不如在这里拦住并说明
          onPressed: readiness.canStartTask ? onStart : null,
          icon: const Icon(Icons.add, size: 16),
          label: const Padding(
            padding: EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            child: Text('导入第一条成片'),
          ),
        ),
        if (blocked != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(blocked,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  height: 1.6,
                  color: AppColors.orange)),
        ],
        const SizedBox(height: AppSpacing.sm),
        TextButton(
          key: const Key('welcome-help'),
          onPressed: () => showHelpSheet(context),
          child: const Text('查看使用说明'),
        ),
      ],
    );
  }
}

/// 准备工作清单。
///
/// 全部就绪时收成一行——一切正常还把三行检查项摊开，只是在给用户增加噪音；
/// 有问题时直接展开，不需要用户先点开才发现自己缺东西。
class _ReadinessPanel extends StatelessWidget {
  final Readiness readiness;
  final VoidCallback onOpenSettings;

  const _ReadinessPanel(
      {required this.readiness, required this.onOpenSettings});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.border),
        ),
        child: readiness.allReady ? _collapsed(context) : _expanded(context),
      );

  Widget _collapsed(BuildContext context) => Row(
        children: [
          const _Dot(ready: true),
          const SizedBox(width: AppSpacing.sm),
          const Expanded(
            child: Text('运行环境已就绪，可以开始了',
                style: TextStyle(
                    fontSize: AppFontSize.body, color: AppColors.textPrimary)),
          ),
          TextButton(
            key: const Key('welcome-open-settings'),
            onPressed: onOpenSettings,
            child: const Text('查看详情'),
          ),
        ],
      );

  Widget _expanded(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('准备工作',
                    style: TextStyle(
                        fontSize: AppFontSize.emphasis,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
              ),
              TextButton(
                key: const Key('welcome-open-settings'),
                onPressed: onOpenSettings,
                child: const Text('去设置核对'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          for (final item in readiness.items) _ItemRow(item: item),
        ],
      );
}

class _ItemRow extends StatelessWidget {
  final ReadinessItem item;

  const _ItemRow({required this.item});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: _Dot(ready: item.ready, checking: item.checking),
            ),
            const SizedBox(width: AppSpacing.md),
            SizedBox(
              width: 108,
              child: Text(item.title,
                  style: const TextStyle(
                      fontSize: AppFontSize.body,
                      color: AppColors.textSecondary)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.statusText,
                      style: TextStyle(
                          fontSize: AppFontSize.body,
                          color: item.ready
                              ? AppColors.textPrimary
                              : AppColors.orange)),
                  if (item.hint != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(item.hint!,
                        style: const TextStyle(
                            fontSize: AppFontSize.caption,
                            height: 1.6,
                            color: AppColors.textTertiary)),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}

class _Dot extends StatelessWidget {
  final bool ready;
  final bool checking;

  const _Dot({required this.ready, this.checking = false});

  @override
  Widget build(BuildContext context) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: checking
              ? AppColors.textTertiary
              : (ready ? AppColors.green : AppColors.orange),
          shape: BoxShape.circle,
        ),
      );
}
