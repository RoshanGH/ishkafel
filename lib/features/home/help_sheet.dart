import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import 'workflow_steps.dart';

/// 「使用说明」。
///
/// 常驻可达（首页与顶栏都有入口），而不是只在没有任务时露一次脸——
/// 忘掉流程的时刻，恰恰是列表里已经堆了一屏任务的时候。
Future<void> showHelpSheet(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _HelpDialog(),
    );

class _HelpDialog extends StatelessWidget {
  const _HelpDialog();

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.xl,
                    AppSpacing.xl, AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('使用说明',
                        style: TextStyle(
                            fontSize: AppFontSize.title,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: AppSpacing.sm),
                    Text(productTagline,
                        style: const TextStyle(
                            fontSize: AppFontSize.body,
                            height: 1.6,
                            color: AppColors.textSecondary)),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const WorkflowStepsStrip(horizontal: false),
                      const SizedBox(height: AppSpacing.sm),
                      const _Section(
                        title: '两层切分是什么',
                        body: '「台词语义单元」按台词想表达的意思切，可能一句话，也可能几句话；'
                            '「视觉镜头」是这个单元内部的画面切换。替换时可以整个单元换一条素材，'
                            '也可以按镜头逐个换——台词与配音始终不动。',
                      ),
                      _Section(
                        title: '为什么要选标签组',
                        body: '标签组是打标的受控词表，AI 只会使用组内的标签。'
                            '它同时也是后续「按相同标签检索候选素材」的唯一依据——'
                            '不选就没有候选素材可用。',
                      ),
                      _Section(
                        title: '快捷键',
                        body: '空格 播放/暂停　·　J K L 走带　·　← → 逐帧　·　⇧ ← → 10 帧\n'
                            '↑ ↓ 切换选中　·　Home / End 跳片头片尾　·　⌘Z / ⇧⌘Z 撤销重做',
                      ),
                      const _Section(
                        title: '遇到问题',
                        body: '设置页里有「运行环境」体检（外部工具的实际路径与版本）与'
                            '「缓存管理」。反馈问题时，附上设置 → 关于里的版本号能省掉大半来回。',
                      ),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('知道了')),
                ),
              ),
            ],
          ),
        ),
      );
}

class _Section extends StatelessWidget {
  final String title;
  final String body;

  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: AppFontSize.emphasis,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: AppSpacing.xs),
            Text(body,
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    height: 1.7,
                    color: AppColors.textSecondary)),
          ],
        ),
      );
}
